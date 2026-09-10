require "./images_spec"

# Simulates a daemon crash immediately before/after the runtime side effect.
class CrashRuntime < Sandcube::Runtime
  getter containers = {} of String => String
  getter calls = [] of String
  property fault : String? = nil
  property after = false
  property fatal = false

  def request(method : String, path : String, body : String? = nil) : JSON::Any
    action = method == "DELETE" ? "delete" : path.split('/').last
    @calls << action
    trip(action) unless @after
    id = path == "/containers" && method == "POST" ? JSON.parse(body.not_nil!)["id"].as_s : path.split('/')[2]?
    value = if path == "/reconcile"
              JSON.parse("{}")
            elsif method == "GET" && path == "/containers"
              JSON.parse(@containers.map { |k, v| {id: k, status: v} }.to_json)
            elsif method == "POST" && path == "/containers"
              @containers[id.not_nil!] ||= "stopped"
              JSON.parse({id: id, status: @containers[id]}.to_json)
            elsif method == "DELETE"
              @containers.delete(id)
              JSON.parse({id: id, status: "deleted"}.to_json)
            else
              raise Sandcube::RuntimeError.new(404, "{}") unless @containers.has_key?(id)
              @containers[id.not_nil!] = "running" if action == "start"
              @containers[id.not_nil!] = "stopped" if action == "stop"
              JSON.parse({id: id, status: @containers[id]}.to_json)
            end
    trip(action) if @after
    value
  end

  def trip(action)
    if @fault == action
      @fault = nil
      raise Sandcube::RuntimeError.new(500, %({"error":{"code":"INJECTED"}})) if fatal
      raise IO::Error.new("injected lost connection at #{action}")
    end
  end
end

if url = ENV["TEST_DATABASE_URL"]? || ENV["DATABASE_URL"]?
  describe Sandcube::Reliability do
    {false, true}.each do |after|
      {"containers", "start", "stop", "delete"}.each do |point|
        it "recovers #{after ? "after" : "before"} #{point} with durable retries" do
          with_image_test_database(url) do |db|
            Sandcube::ImageStore.new(db)
            runtime = CrashRuntime.new
            manager = Sandcube::Reliability.new(db, runtime)
            body = %({"image":"test","command":["sleep","infinity"]})
            path = "/v1/sandboxes"
            if point == "containers" || point == "start"
              runtime.fault = point
              runtime.after = after
              expect_raises(IO::Error) { manager.request("POST", path, body, "retry") }
            else
              created = manager.request("POST", path, body, "create")
              path += "/#{created["id"].as_s}"
              path += "/stop" if point == "stop"
              runtime.fault = point
              runtime.after = after
              expect_raises(IO::Error) { manager.request(point == "delete" ? "DELETE" : "POST", path, nil, "retry") }
            end
            restarted = Sandcube::Reliability.new(db, runtime)
            restarted.reconcile
            method = point == "delete" ? "DELETE" : "POST"
            result = restarted.request(method, path, point == "containers" || point == "start" ? body : nil, "retry")
            result["status"].as_s.should eq(point == "delete" ? "deleted" : point == "stop" ? "stopped" : "running")
            calls = runtime.calls.size
            restarted.request(method, path, point == "containers" || point == "start" ? body : nil, "retry").should eq(result)
            runtime.calls.size.should eq(calls)
            db.query_one("SELECT count(*) FROM sandboxes", as: Int64).should eq(1)
          end
        end
      end
    end
    it "compensates definitive create failure and replays the original error" do
      with_image_test_database(url) do |db|
        Sandcube::ImageStore.new(db)
        runtime = CrashRuntime.new
        manager = Sandcube::Reliability.new(db, runtime)
        runtime.fault = "start"
        runtime.fatal = true
        body = %({"image":"test","command":["missing"]})
        expect_raises(Sandcube::RuntimeError) { manager.request("POST", "/v1/sandboxes", body, "failed") }
        runtime.containers.should be_empty
        calls = runtime.calls.size
        expect_raises(Sandcube::RuntimeError) { Sandcube::Reliability.new(db, runtime).request("POST", "/v1/sandboxes", body, "failed") }
        runtime.calls.size.should eq(calls)
      end
    end

    it "does not repeat the stop phase when restart loses its start response" do
      with_image_test_database(url) do |db|
        Sandcube::ImageStore.new(db)
        runtime = CrashRuntime.new
        manager = Sandcube::Reliability.new(db, runtime)
        row = manager.request("POST", "/v1/sandboxes", %({"image":"test","command":["sleep"]}), nil)
        path = "/v1/sandboxes/#{row["id"].as_s}/restart"
        runtime.fault = "start"
        runtime.after = true
        expect_raises(IO::Error) { manager.request("POST", path, nil, "restart") }
        runtime.calls.count("stop").should eq(1)
        manager = Sandcube::Reliability.new(db, runtime)
        manager.reconcile
        manager.request("POST", path, nil, "restart")["status"].as_s.should eq("running")
        runtime.calls.count("stop").should eq(1)
      end
    end

    it "retains image reservations through failed TTL cleanup and retries deletion" do
      with_image_test_database(url) do |db|
        images = Sandcube::ImageStore.new(db)
        images.create("img_ttl", nil, "FROM scratch")
        images.ready("img_ttl", "sha256:test")
        runtime = CrashRuntime.new
        manager = Sandcube::Reliability.new(db, runtime)
        manager.request("POST", "/v1/sandboxes", %({"image_id":"img_ttl","command":["sleep"],"ttl_seconds":10}), nil)
        db.exec("UPDATE sandboxes SET expires_at=now()-interval '1 second'")
        runtime.fault = "delete"
        manager.reconcile
        expect_raises(Sandcube::ImageError) { images.begin_delete("img_ttl") }
        manager.metrics.should contain("sandcube_cleanup_failures_total 1")
        manager.reconcile
        runtime.containers.should be_empty
        db.query_one("SELECT count(*) FROM sandbox_images", as: Int64).should eq(0)
      end
    end

    it "serializes concurrent same-key creates across service instances and rejects key reuse" do
      with_image_test_database(url) do |db|
        Sandcube::ImageStore.new(db)
        runtime = CrashRuntime.new
        a = Sandcube::Reliability.new(db, runtime)
        b = Sandcube::Reliability.new(db, runtime)
        results = Channel(JSON::Any).new
        body = %({"image":"test","command":["sleep"]})
        8.times { |i| spawn { results.send((i.even? ? a : b).request("POST", "/v1/sandboxes", body, "same")) } }
        values = Array.new(8) { results.receive }
        values.uniq.size.should eq(1)
        runtime.containers.size.should eq(1)
        expect_raises(Sandcube::ImageError, "Key was used") { b.request("POST", "/v1/sandboxes", "{}", "same") }
      end
    end
    it "expires running and stopped sandboxes, releases reservations and preserves reusable images" do
      with_image_test_database(url) do |db|
        images = Sandcube::ImageStore.new(db)
        images.create("img_test", nil, "FROM scratch")
        images.ready("img_test", "sha256:test")
        runtime = CrashRuntime.new
        manager = Sandcube::Reliability.new(db, runtime)
        2.times do |i|
          row = manager.request("POST", "/v1/sandboxes", %({"image_id":"img_test","command":["sleep"],"ttl_seconds":100}), nil)
          manager.request("POST", "/v1/sandboxes/#{row["id"].as_s}/stop", nil, nil) if i == 1
        end
        db.exec("UPDATE sandboxes SET expires_at=now()-interval '1 second'")
        runtime.containers["sbx_orphan"] = "running"
        manager.reconcile
        runtime.containers.should be_empty
        db.query_one("SELECT count(*) FROM sandbox_images", as: Int64).should eq(0)
        images.get("img_test")["status"].as_s.should eq("READY")
        manager.metrics.should contain("sandcube_orphans_cleaned_total 1")
        manager.metrics.should contain("sandcube_cleanup_completed_total 2")
      end
    end
    it "does not clean resources when inventory fails and reports missing containers accurately" do
      with_image_test_database(url) do |db|
        Sandcube::ImageStore.new(db)
        runtime = CrashRuntime.new
        manager = Sandcube::Reliability.new(db, runtime)
        row = manager.request("POST", "/v1/sandboxes", %({"image":"test","command":["sleep"]}), nil)
        runtime.fault = "containers"
        manager.reconcile
        runtime.containers.size.should eq(1)
        runtime.containers.clear
        manager.reconcile
        manager.inspect(row["id"].as_s)["status"].as_s.should eq("error")
      end
    end
  end
else
  pending "Reliability database tests require TEST_DATABASE_URL or DATABASE_URL"
end
