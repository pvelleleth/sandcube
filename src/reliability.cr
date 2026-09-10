require "digest/sha256"
require "./images/store"

module Sandcube
  # A single host-wide database lock serializes lifecycle intent, runtime operations,
  # image reservations and sweeps across API processes. Intent commits BEFORE IO.
  # A lost lock connection releases the lock; adapter operations are themselves
  # idempotent and serialized. Only the lock transaction spans runtime IO.
  class Reliability
    @@local_lock = Mutex.new

    def initialize(@db : DB::Database, @runtime : Runtime)
      {{ read_file("#{__DIR__}/../migrations/002_reliability.sql") }}.split(';').each do |sql|
        @db.exec(sql) unless sql.strip.empty?
      end
    end

    def locked(&block : DB::Connection -> T) : T forall T
      # Pin the lock connection in a transaction, including with PgBouncer in
      # transaction mode. Journal commits use a second connection so a crash
      # rolls back only the lock transaction, never the accepted intent.
      result = uninitialized T
      @@local_lock.synchronize do
        @db.using_connection do |lock_conn|
          lock_conn.transaction do
            lock_conn.exec("SELECT pg_advisory_xact_lock(1935764580)")
            @db.using_connection { |conn| result = yield conn }
          end
        end
      end
      result
    end

    def count(conn, name)
      conn.exec("INSERT INTO reliability_counters(name,value) VALUES($1,1) ON CONFLICT(name) DO UPDATE SET value=reliability_counters.value+1", name)
    end

    def event(name, id = "", message = "", duration_ms : Float64? = nil)
      level = name.ends_with?("failed") || name.ends_with?("unavailable") || name.ends_with?("error") ? "error" : "info"
      STDOUT.puts({time: Time.utc.to_rfc3339, level: level, event: name, sandbox_id: id, message: message, duration_ms: duration_ms}.to_json)
    end

    def get(conn, id) : JSON::Any
      raw = conn.query_one?("SELECT row_to_json(sandboxes)::text FROM sandboxes WHERE id=$1", id, as: String)
      raise ImageError.new(404, "SANDBOX_NOT_FOUND", "Sandbox does not exist") unless raw
      JSON.parse(raw)
    end

    def response(conn, id) : JSON::Any
      row = get(conn, id)
      config = row["config"]
      JSON.parse({id: id, status: row["status"], snapshot_key: id, image_id: config["image_id"]?,
                  cpu: config["cpu"], memory_mb: config["memory_mb"], pids: config["pids"],
                  expires_at: row["expires_at"], error_message: row["error_message"]}.to_json)
    end

    def request(method : String, path : String, body : String?, key : String?) : JSON::Any
      action = path == "/v1/sandboxes" ? "create" : (method == "DELETE" ? "delete" : path.split('/').last)
      raise ArgumentError.new("Idempotency-Key must contain 1–200 printable ASCII characters") if key && (key.empty? || key.bytesize > 200 || !key.each_byte.all? { |c| c >= 33 && c <= 126 })
      raise ArgumentError.new("Unsupported lifecycle operation") unless {"create", "start", "stop", "restart", "delete"}.includes?(action)
      fingerprint = Digest::SHA256.hexdigest("#{method}\n#{path}\n#{body}")
      locked do |conn|
        if key
          previous = conn.query_one?("SELECT fingerprint,sandbox_id,response,response_status FROM lifecycle_requests WHERE key=$1", key, as: {String, String, String?, Int32})
          if previous
            raise ImageError.new(409, "IDEMPOTENCY_CONFLICT", "Key was used for a different request") unless previous[0] == fingerprint
            if saved = previous[2]
              raise RuntimeError.new(previous[3], saved) if previous[3] >= 400
              return JSON.parse(saved)
            end
            converge(conn, previous[1])
            return JSON.parse(conn.query_one("SELECT response FROM lifecycle_requests WHERE key=$1", key, as: String))
          end
        end
        id = action == "create" ? "sbx_#{UUID.random.to_s.gsub("-", "")}" : path.split('/')[3]
        conn.transaction do
          if action == "create"
            input = JSON.parse(body || "{}").as_h
            allowed = {"image", "image_id", "command", "cpu", "memory_mb", "pids", "ttl_seconds"}
            raise ArgumentError.new("Unknown create field") unless input.keys.all? { |k| allowed.includes?(k) }
            raise ArgumentError.new("Provide exactly one of image or image_id") unless input.has_key?("image") != input.has_key?("image_id")
            command = input["command"].as_a.map(&.as_s)
            cpu = input["cpu"]?.try(&.as_i) || 1
            memory = input["memory_mb"]?.try(&.as_i) || 256
            pids = input["pids"]?.try(&.as_i) || 128
            ttl = input["ttl_seconds"]?.try(&.as_i)
            raise ArgumentError.new("Invalid command or resource limits") if command.empty? || command[0].empty? || !(1..64).includes?(cpu) || !(16..262144).includes?(memory) || !(1..65536).includes?(pids)
            raise ArgumentError.new("ttl_seconds must be positive") if ttl && ttl <= 0
            image_id = input["image_id"]?.try(&.as_s)
            image = if image_id
                      row = conn.query_one?("SELECT status,oci_reference FROM images WHERE id=$1 FOR UPDATE", image_id, as: {String, String})
                      raise ImageError.new(404, "IMAGE_NOT_FOUND", "Image does not exist") unless row
                      raise ImageError.new(409, "IMAGE_NOT_READY", "Image is not ready") unless row[0] == "READY"
                      conn.exec("INSERT INTO sandbox_images(sandbox_id,image_id) VALUES($1,$2)", id, image_id)
                      row[1]
                    else
                      input["image"].as_s
                    end
            config = {id: id, image: image, image_id: image_id, command: command, cpu: cpu, memory_mb: memory, pids: pids}
            conn.exec("INSERT INTO sandboxes(id,config,intent,expires_at) VALUES($1,$2::jsonb,'create',$3)", id, config.to_json, ttl.try { |n| Time.utc + n.seconds })
          else
            row = get(conn, id)
            # Complete older accepted work before recording a new transition.
            raise ImageError.new(409, "LIFECYCLE_PENDING", "Previous operation is awaiting reconciliation") unless row["intent"].raw.nil? || action == "delete"
            raise ImageError.new(410, "SANDBOX_DELETED", "Sandbox was deleted") if row["status"].as_s == "deleted" && action != "delete"
            state = {"start" => "starting", "stop" => "stopping", "restart" => "stopping", "delete" => "deleting"}[action]
            conn.exec("UPDATE sandboxes SET intent=$2,status=$3,updated_at=now() WHERE id=$1", id, action, state)
          end
          if key
            conn.exec("INSERT INTO lifecycle_requests(key,fingerprint,sandbox_id,action) VALUES($1,$2,$3,$4)", key, fingerprint, id, action)
          end
        end
        converge(conn, id)
        response(conn, id)
      end
    end

    def converge(conn, id)
      row = get(conn, id)
      intent = row["intent"].as_s?
      return unless intent
      started = Time.instant
      begin
        case intent
        when "create"
          config = row["config"].as_h.dup
          config.delete("image_id")
          @runtime.request("POST", "/containers", config.to_json)
          @runtime.request("POST", "/containers/#{id}/start")
        when "start"
          @runtime.request("POST", "/containers/#{id}/start")
        when "restart"
          @runtime.request("POST", "/containers/#{id}/stop")
          conn.exec("UPDATE sandboxes SET intent='start' WHERE id=$1", id)
          @runtime.request("POST", "/containers/#{id}/start")
        when "stop"
          @runtime.request("POST", "/containers/#{id}/stop")
        when "delete"
          @runtime.request("DELETE", "/containers/#{id}")
        end
        status = intent == "delete" ? "deleted" : (intent == "stop" ? "stopped" : "running")
        conn.transaction do
          conn.exec("UPDATE sandboxes SET status=$2,intent=NULL,error_message=NULL,updated_at=now() WHERE id=$1", id, status)
          conn.exec("DELETE FROM sandbox_images WHERE sandbox_id=$1", id) if status == "deleted"
          conn.exec("UPDATE lifecycle_requests SET response=$2 WHERE sandbox_id=$1 AND response IS NULL", id, response(conn, id).to_json)
          count(conn, "lifecycle_completed")
          count(conn, "cleanup_completed") if status == "deleted"
        end
        event("sandbox.#{intent}", id, "", (Time.instant - started).total_milliseconds)
      rescue ex
        conn.exec("UPDATE sandboxes SET error_message=$2,updated_at=now() WHERE id=$1", id, ex.message)
        count(conn, "runtime_failures")
        count(conn, "cleanup_failures") if intent == "delete"
        event("runtime.error", id, ex.message || "")
        if intent == "create" && ex.is_a?(RuntimeError)
          # A definitive failed create is compensated; transport failures retain
          # the original intent because the runtime may have succeeded.
          conn.transaction do
            conn.exec("UPDATE sandboxes SET intent='delete',status='deleting' WHERE id=$1", id)
            conn.exec("UPDATE lifecycle_requests SET response=$2,response_status=$3 WHERE sandbox_id=$1 AND response IS NULL", id, ex.body, ex.status)
          end
          begin
            converge(conn, id)
          rescue cleanup
            event("cleanup.failed", id, cleanup.message || "")
          end
        end
        raise ex
      end
    end

    def reconcile
      locked do |conn|
        # Inventory failure must never be interpreted as an empty runtime.
        inventory = @runtime.request("GET", "/containers").as_a
        ids = conn.query_all("SELECT id FROM sandboxes WHERE status != 'deleted' OR intent IS NOT NULL", as: String)
        ids.each do |id|
          begin
            expired = conn.query_one("SELECT COALESCE(expires_at <= now(),false) FROM sandboxes WHERE id=$1", id, as: Bool)
            if expired
              # Finish any pending retry response before recording expiration.
              # Pending work is superseded by deletion, never restarted after TTL.
              conn.exec("UPDATE sandboxes SET intent='delete',status='deleting' WHERE id=$1", id)
            end
            converge(conn, id)
            row = get(conn, id)
            next if row["status"].as_s == "deleted"
            begin
              actual = @runtime.request("GET", "/containers/#{id}")
              conn.exec("UPDATE sandboxes SET status=$2,error_message=NULL,updated_at=now() WHERE id=$1", id, actual["status"].as_s)
            rescue ex : RuntimeError
              raise ex unless ex.status == 404
              conn.exec("UPDATE sandboxes SET status='error',error_message='Runtime container missing',updated_at=now() WHERE id=$1", id)
            end
          rescue ex
            count(conn, "reconcile_failures")
            event("reconcile.failed", id, ex.message || "")
          end
        end
        inventory.each do |container|
          id = container["id"].as_s
          next if ids.includes?(id) # already reconciled using fresh runtime responses
          known = conn.query_one?("SELECT status FROM sandboxes WHERE id=$1", id, as: String)
          next if known && known != "deleted"
          begin
            @runtime.request("DELETE", "/containers/#{id}")
            conn.exec("DELETE FROM sandbox_images WHERE sandbox_id=$1", id)
            count(conn, "orphans_cleaned")
            event("orphan.cleaned", id)
          rescue ex
            count(conn, "cleanup_failures")
            event("cleanup.failed", id, ex.message || "")
          end
        end
        # Adapter cleans only positively labelled snapshots, under its own lock.
        @runtime.request("POST", "/reconcile")
        count(conn, "reconcile_completed")
      end
    rescue ex
      event("reconcile.unavailable", "", ex.message || "")
    end

    def health
      @db.query_one("SELECT 1", as: Int32)
    end

    def inspect(id)
      locked { |conn| response(conn, id) }
    end

    def metrics
      @db.query_one("SELECT 1", as: Int32)
      values = {} of String => Int64
      @db.query("SELECT name,value FROM reliability_counters") { |rs| rs.each { values["sandcube_#{rs.read(String)}_total"] = rs.read(Int64) } }
      {"running", "stopped", "error"}.each do |state|
        values["sandcube_sandboxes_#{state}"] = @db.query_one("SELECT count(*) FROM sandboxes WHERE status=$1", state, as: Int64)
      end
      {"cpu", "memory_mb"}.each do |field|
        values["sandcube_allocated_#{field}"] = @db.query_one("SELECT COALESCE(sum((config->>$1)::bigint),0)::bigint FROM sandboxes WHERE status='running'", field, as: Int64)
      end
      output = values.map { |name, value| "#{name} #{value}\n" }.join
      begin
        output += @runtime.request("GET", "/metrics")["prometheus"].as_s
        output += "sandcube_runtime_up 1\n"
      rescue
        output += "sandcube_runtime_up 0\n"
      end
      output
    end
  end
end
