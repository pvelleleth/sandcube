require "./reliability_spec"

private class PausedRuntime < CrashRuntime
  getter entered = Channel(Nil).new(1)
  getter resume = Channel(Nil).new(1)

  def request(method : String, path : String, body : String? = nil) : JSON::Any
    if path.ends_with?("/start")
      entered.send(nil)
      resume.receive
    end
    super
  end
end

describe Sandcube::Database do
  it "allows health and image updates while a lifecycle operation waits on the runtime" do
    with_image_test_database do |db|
      runtime = PausedRuntime.new
      manager = Sandcube::Reliability.new(db, runtime)
      store = Sandcube::ImageStore.new(db)
      store.create("img_parallel", nil, "FROM scratch")
      result = Channel(JSON::Any | Exception).new(1)
      spawn do
        begin
          result.send(manager.request("POST", "/v1/sandboxes", %({"image":"test","command":["sleep"]}), nil))
        rescue ex
          result.send(ex)
        end
      end
      runtime.entered.receive
      begin
        manager.health.should eq(1)
        store.ready("img_parallel", "sha256:test")
        store.get("img_parallel")["status"].as_s.should eq("READY")
      ensure
        runtime.resume.send(nil)
      end
      value = result.receive
      raise value if value.is_a?(Exception)
      value["status"].as_s.should eq("running")
    end
  end

  it "persists intent, image reservations and retry responses across database reopen" do
    path = File.tempname("sandcube-reopen-", ".db")
    runtime = CrashRuntime.new
    db = Sandcube::Database.open(path)
    begin
      store = Sandcube::ImageStore.new(db)
      store.create("img_durable", "durable", "FROM scratch")
      store.ready("img_durable", "sha256:test")
      manager = Sandcube::Reliability.new(db, runtime)
      runtime.fault = "start"
      body = %({"image_id":"img_durable","command":["sleep"],"ttl_seconds":60})
      expect_raises(IO::Error) { manager.request("POST", "/v1/sandboxes", body, "durable-key") }
      db.close
      db = Sandcube::Database.open(path)
      recovered = Sandcube::Reliability.new(db, runtime)
      recovered.reconcile
      response = recovered.request("POST", "/v1/sandboxes", body, "durable-key")
      response["status"].as_s.should eq("running")
      Time.parse_rfc3339(response["expires_at"].as_s).should be > Time.utc
      store = Sandcube::ImageStore.new(db)
      store.image_id(response["id"].as_s).should eq("img_durable")
      expect_raises(Sandcube::ImageError, /referenced/) { store.begin_delete("img_durable") }
      db.query_one("PRAGMA foreign_keys", as: Int32).should eq(1)
      db.query_one("PRAGMA journal_mode", as: String).should eq("wal")
      db.query_one("PRAGMA integrity_check", as: String).should eq("ok")
      (File.info(path).permissions.value & 0o777).should eq(0o600)
      db.close
      db = Sandcube::Database.open(path)
      calls = runtime.calls.size
      Sandcube::Reliability.new(db, runtime).request("POST", "/v1/sandboxes", body, "durable-key").should eq(response)
      runtime.calls.size.should eq(calls)
    ensure
      db.close
      File.delete(path)
    end
  end
end
