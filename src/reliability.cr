require "digest/sha256"
require "./images/store"
require "./capacity"

module Sandcube
  # One API process per host, enforced by the API lifetime file lock.
  # Lifecycle intent commits before runtime IO, so recovery survives crashes.
  class Reliability
    @@local_lock = Mutex.new

    def initialize(@db : DB::Database, @runtime : Runtime, @capacity : Capacity = Capacity.new)
      @db.using_connection do |conn|
        conn.transaction do
          @capacity.configure(conn)
        end
      end
    end

    def locked(&block : DB::Database -> T) : T forall T
      result = uninitialized T
      @@local_lock.synchronize do
        # Do not pin SQLite's connection while waiting on the runtime. Image
        # builds, health and metrics must still be able to access metadata.
        result = yield @db
      end
      result
    end

    def count(conn, name)
      conn.exec("INSERT INTO reliability_counters(name,value) VALUES(?1,1) ON CONFLICT(name) DO UPDATE SET value=reliability_counters.value+1", name)
    end

    def event(name, id = "", message = "", duration_ms : Float64? = nil)
      level = name.ends_with?("failed") || name.ends_with?("unavailable") || name.ends_with?("error") ? "error" : "info"
      STDOUT.puts({time: Time.utc.to_rfc3339, level: level, event: name, sandbox_id: id, message: message, duration_ms: duration_ms}.to_json)
    end

    def get(conn, id) : JSON::Any
      raw = conn.query_one?("SELECT json_object('id',id,'config',json(config),'status',status,'intent',intent,'expires_at',expires_at,'error_message',error_message) FROM sandboxes WHERE id=?1", id, as: String)
      raise ImageError.new(404, "SANDBOX_NOT_FOUND", "Sandbox does not exist") unless raw
      JSON.parse(raw)
    end

    def response(conn, id) : JSON::Any
      row = get(conn, id)
      config = row["config"]
      JSON.parse({id: id, status: row["status"], snapshot_key: id, image_id: config["image_id"]?,
                  disk_mb: config["disk_mb"], cpu: config["cpu"], memory_mb: config["memory_mb"], pids: config["pids"],
                  expires_at: row["expires_at"], error_message: row["error_message"]}.to_json)
    end

    def request(method : String, path : String, body : String?, key : String?) : JSON::Any
      action = path == "/v1/sandboxes" ? "create" : (method == "DELETE" ? "delete" : path.split('/').last)
      raise ArgumentError.new("Idempotency-Key must contain 1–200 printable ASCII characters") if key && (key.empty? || key.bytesize > 200 || !key.each_byte.all? { |c| c >= 33 && c <= 126 })
      raise ArgumentError.new("Unsupported lifecycle operation") unless {"create", "start", "stop", "restart", "delete"}.includes?(action)
      fingerprint = Digest::SHA256.hexdigest("#{method}\n#{path}\n#{body}")
      locked do |conn|
        if key
          previous = conn.query_one?("SELECT fingerprint,sandbox_id,response,response_status FROM lifecycle_requests WHERE key=?1", key, as: {String, String, String?, Int32})
          if previous
            raise ImageError.new(409, "IDEMPOTENCY_CONFLICT", "Key was used for a different request") unless previous[0] == fingerprint
            if saved = previous[2]
              raise RuntimeError.new(previous[3], saved) if previous[3] >= 400
              return JSON.parse(saved)
            end
            converge(conn, previous[1])
            return JSON.parse(conn.query_one("SELECT response FROM lifecycle_requests WHERE key=?1", key, as: String))
          end
        end
        if {"create", "start", "restart"}.includes?(action)
          # Unknown runtime objects have no trustworthy reservation. Wait for
          # orphan cleanup instead of admitting work against incomplete capacity.
          @runtime.request("GET", "/containers").as_a.each do |container|
            known = conn.query_one?("SELECT id FROM sandboxes WHERE id=?1 AND status!='deleted'", container["id"].as_s, as: String)
            raise ImageError.new(503, "CAPACITY_UNAVAILABLE", "Runtime inventory contains an unaccounted sandbox; reconciliation is required") unless known
          end
        end
        id = action == "create" ? "sbx_#{UUID.random.to_s.gsub("-", "")}" : path.split('/')[3]
        conn.transaction do |tx|
          journal = tx.connection
          if action == "create"
            input = JSON.parse(body || "{}").as_h
            allowed = {"image", "image_id", "command", "cpu", "memory_mb", "pids", "disk_mb", "ttl_seconds"}
            raise ArgumentError.new("Unknown create field") unless input.keys.all? { |k| allowed.includes?(k) }
            raise ArgumentError.new("Provide exactly one of image or image_id") unless input.has_key?("image") != input.has_key?("image_id")
            command = input["command"].as_a.map(&.as_s)
            cpu = input["cpu"]?.try(&.as_i) || 1
            memory = input["memory_mb"]?.try(&.as_i) || 256
            disk = input["disk_mb"]?.try(&.as_i) || 1024
            pids = input["pids"]?.try(&.as_i) || 128
            ttl = input["ttl_seconds"]?.try(&.as_i)
            raise ArgumentError.new("Invalid command or resource limits") if !(16..1048576).includes?(disk) || command.empty? || command[0].empty? || !(1..64).includes?(cpu) || !(16..262144).includes?(memory) || !(1..65536).includes?(pids)
            raise ArgumentError.new("ttl_seconds must be positive") if ttl && ttl <= 0
            image_id = input["image_id"]?.try(&.as_s)
            image = if image_id
                      row = journal.query_one?("SELECT status,oci_reference FROM images WHERE id=?1", image_id, as: {String, String})
                      raise ImageError.new(404, "IMAGE_NOT_FOUND", "Image does not exist") unless row
                      raise ImageError.new(409, "IMAGE_NOT_READY", "Image is not ready") unless row[0] == "READY"
                      journal.exec("INSERT INTO sandbox_images(sandbox_id,image_id) VALUES(?1,?2)", id, image_id)
                      row[1]
                    else
                      input["image"].as_s
                    end
            config = {id: id, image: image, image_id: image_id, command: command, cpu: cpu, memory_mb: memory, disk_mb: disk, pids: pids}
            journal.exec("INSERT INTO sandboxes(id,config,intent,expires_at) VALUES(?1,?2,'create',?3)", id, config.to_json, ttl.try { |n| (Time.utc + n.seconds).to_rfc3339 })
            @capacity.reserve(journal, id, cpu.to_i64, memory.to_i64, disk.to_i64)
          else
            row = get(journal, id)
            # Complete older accepted work before recording a new transition.
            raise ImageError.new(409, "LIFECYCLE_PENDING", "Previous operation is awaiting reconciliation") unless row["intent"].raw.nil? || action == "delete"
            raise ImageError.new(410, "SANDBOX_DELETED", "Sandbox was deleted") if row["status"].as_s == "deleted" && action != "delete"
            if {"start", "restart"}.includes?(action)
              config = row["config"]
              @capacity.reserve(journal, id, config["cpu"].as_i64, config["memory_mb"].as_i64, config["disk_mb"].as_i64)
            end
            state = {"start" => "starting", "stop" => "stopping", "restart" => "stopping", "delete" => "deleting"}[action]
            journal.exec("UPDATE sandboxes SET intent=?2,status=?3,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?1", id, action, state)
          end
          if key
            journal.exec("INSERT INTO lifecycle_requests(key,fingerprint,sandbox_id,action) VALUES(?1,?2,?3,?4)", key, fingerprint, id, action)
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
          conn.exec("UPDATE sandboxes SET intent='start' WHERE id=?1", id)
          @runtime.request("POST", "/containers/#{id}/start")
        when "stop"
          @runtime.request("POST", "/containers/#{id}/stop")
        when "delete"
          @runtime.request("DELETE", "/containers/#{id}")
        end
        status = intent == "delete" ? "deleted" : (intent == "stop" ? "stopped" : "running")
        conn.transaction do |tx|
          journal = tx.connection
          journal.exec("UPDATE sandboxes SET status=?2,intent=NULL,error_message=NULL,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?1", id, status)
          journal.exec("UPDATE sandboxes SET reserved_cpu=0,reserved_memory_mb=0 WHERE id=?1", id) if {"stopped", "deleted"}.includes?(status)
          journal.exec("UPDATE sandboxes SET reserved_disk_mb=0 WHERE id=?1", id) if status == "deleted"
          journal.exec("DELETE FROM sandbox_images WHERE sandbox_id=?1", id) if status == "deleted"
          journal.exec("UPDATE lifecycle_requests SET response=?2 WHERE sandbox_id=?1 AND response IS NULL", id, response(journal, id).to_json)
          count(journal, "lifecycle_completed")
          count(journal, "cleanup_completed") if status == "deleted"
        end
        event("sandbox.#{intent}", id, "", (Time.instant - started).total_milliseconds)
      rescue ex
        conn.exec("UPDATE sandboxes SET error_message=?2,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?1", id, ex.message)
        count(conn, "runtime_failures")
        count(conn, "cleanup_failures") if intent == "delete"
        event("runtime.error", id, ex.message || "")
        if intent == "create" && ex.is_a?(RuntimeError)
          # A definitive failed create is compensated; transport failures retain
          # the original intent because the runtime may have succeeded.
          conn.transaction do |tx|
            tx.connection.exec("UPDATE sandboxes SET intent='delete',status='deleting' WHERE id=?1", id)
            tx.connection.exec("UPDATE lifecycle_requests SET response=?2,response_status=?3 WHERE sandbox_id=?1 AND response IS NULL", id, ex.body, ex.status)
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
            expired = conn.query_one("SELECT COALESCE(julianday(expires_at) <= julianday('now'),false) FROM sandboxes WHERE id=?1", id, as: Bool)
            if expired
              # Finish any pending retry response before recording expiration.
              # Pending work is superseded by deletion, never restarted after TTL.
              conn.exec("UPDATE sandboxes SET intent='delete',status='deleting' WHERE id=?1", id)
            end
            converge(conn, id)
            row = get(conn, id)
            next if row["status"].as_s == "deleted"
            begin
              actual = @runtime.request("GET", "/containers/#{id}")
              conn.exec("UPDATE sandboxes SET status=?2,error_message=NULL,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?1", id, actual["status"].as_s)
              conn.exec("UPDATE sandboxes SET reserved_cpu=0,reserved_memory_mb=0 WHERE id=?1", id) if actual["status"].as_s == "stopped"
            rescue ex : RuntimeError
              raise ex unless ex.status == 404
              conn.exec("UPDATE sandboxes SET status='error',error_message='Runtime container missing',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?1", id)
            end
          rescue ex
            count(conn, "reconcile_failures")
            event("reconcile.failed", id, ex.message || "")
          end
        end
        inventory.each do |container|
          id = container["id"].as_s
          next if ids.includes?(id) # already reconciled using fresh runtime responses
          known = conn.query_one?("SELECT status FROM sandboxes WHERE id=?1", id, as: String)
          next if known && known != "deleted"
          begin
            @runtime.request("DELETE", "/containers/#{id}")
            conn.exec("DELETE FROM sandbox_images WHERE sandbox_id=?1", id)
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
        values["sandcube_sandboxes_#{state}"] = @db.query_one("SELECT count(*) FROM sandboxes WHERE status=?1", state, as: Int64)
      end
      {"cpu", "memory_mb", "disk_mb"}.each do |field|
        values["sandcube_allocated_#{field}"] = @db.query_one("SELECT COALESCE(sum(reserved_#{field}),0) FROM sandboxes", as: Int64)
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
