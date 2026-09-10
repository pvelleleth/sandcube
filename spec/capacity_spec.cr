require "./reliability_spec"

if url = ENV["TEST_DATABASE_URL"]? || ENV["DATABASE_URL"]?
  describe Sandcube::Capacity do
    it "rejects conflicting host budgets without changing existing reservations" do
      with_image_test_database(url) do |db|
        Sandcube::ImageStore.new(db)
        runtime = CrashRuntime.new
        manager = Sandcube::Reliability.new(db, runtime, Sandcube::Capacity.new(1_i64, 256_i64, 32_i64))
        manager.request("POST", "/v1/sandboxes", %({"image":"test","command":["sleep"],"disk_mb":32}), nil)
        expect_raises(ArgumentError, "persisted budgets") do
          Sandcube::Reliability.new(db, runtime, Sandcube::Capacity.new(2_i64, 512_i64, 64_i64))
        end
        manager.metrics.should contain("sandcube_allocated_disk_mb 32")
        db.query_one("SELECT cpu FROM host_capacity", as: Int64).should eq(1)
      end
    end

    it "admits only one concurrent create at capacity across coordinators" do
      with_image_test_database(url) do |db|
        Sandcube::ImageStore.new(db)
        runtime = CrashRuntime.new
        a = Sandcube::Reliability.new(db, runtime, Sandcube::Capacity.new(1_i64, 256_i64, 32_i64))
        b = Sandcube::Reliability.new(db, runtime, Sandcube::Capacity.new(1_i64, 256_i64, 32_i64))
        results = Channel(String).new
        8.times do |i|
          spawn do
            begin
              (i.even? ? a : b).request("POST", "/v1/sandboxes", %({"image":"test","command":["sleep"],"disk_mb":32}), nil)
              results.send("ok")
            rescue ex : Sandcube::ImageError
              results.send(ex.code)
            end
          end
        end
        values = Array.new(8) { results.receive }
        values.count("ok").should eq(1)
        values.count("INSUFFICIENT_CAPACITY").should eq(7)
        runtime.containers.size.should eq(1)
        db.query_one("SELECT count(*) FROM sandboxes", as: Int64).should eq(1)
      end
    end

    it "retains disk on stop and races starts against creates without overcommit" do
      with_image_test_database(url) do |db|
        Sandcube::ImageStore.new(db)
        runtime = CrashRuntime.new
        manager = Sandcube::Reliability.new(db, runtime, Sandcube::Capacity.new(1_i64, 256_i64, 64_i64))
        body = %({"image":"test","command":["sleep"],"disk_mb":32})
        row = manager.request("POST", "/v1/sandboxes", body, nil)
        id = row["id"].as_s
        manager.request("POST", "/v1/sandboxes/#{id}/stop", nil, nil)
        manager.metrics.should contain("sandcube_allocated_cpu 0")
        manager.metrics.should contain("sandcube_allocated_disk_mb 32")
        results = Channel(String).new
        spawn do
          begin
            manager.request("POST", "/v1/sandboxes/#{id}/start", nil, nil)
            results.send("ok")
          rescue ex : Sandcube::ImageError
            results.send(ex.code)
          end
        end
        spawn do
          begin
            manager.request("POST", "/v1/sandboxes", body, nil)
            results.send("ok")
          rescue ex : Sandcube::ImageError
            results.send(ex.code)
          end
        end
        values = Array.new(2) { results.receive }
        values.sort.should eq(["INSUFFICIENT_CAPACITY", "ok"])
        db.query_one("SELECT sum(reserved_cpu)::bigint FROM sandboxes", as: Int64).should eq(1)
        db.query_all("SELECT id FROM sandboxes", as: String).each { |sid| manager.request("DELETE", "/v1/sandboxes/#{sid}", nil, nil) }
        manager.metrics.should contain("sandcube_allocated_disk_mb 0")
      end
    end

    {"cpu", "memory_mb", "disk_mb"}.each do |resource|
      it "rejects exhaustion of #{resource} independently" do
        with_image_test_database(url) do |db|
          Sandcube::ImageStore.new(db)
          runtime = CrashRuntime.new
          capacity = Sandcube::Capacity.new(resource == "cpu" ? 1_i64 : 64_i64, resource == "memory_mb" ? 256_i64 : 4096_i64, resource == "disk_mb" ? 32_i64 : 1024_i64)
          manager = Sandcube::Reliability.new(db, runtime, capacity)
          body = %({"image":"test","command":["sleep"],"disk_mb":32})
          manager.request("POST", "/v1/sandboxes", body, nil)
          expect_raises(Sandcube::ImageError, "capacity is exhausted") { manager.request("POST", "/v1/sandboxes", body, nil) }
        end
      end
    end

    {false, true}.each do |after|
      it "keeps reservations across lost responses, cleanup failure and coordinator recovery (after=#{after})" do
        with_image_test_database(url) do |db|
          Sandcube::ImageStore.new(db)
          runtime = CrashRuntime.new
          capacity = Sandcube::Capacity.new(1_i64, 256_i64, 32_i64)
          manager = Sandcube::Reliability.new(db, runtime, capacity)
          body = %({"image":"test","command":["sleep"],"disk_mb":32})
          runtime.fault = "start"
          runtime.after = after
          expect_raises(IO::Error) { manager.request("POST", "/v1/sandboxes", body, "retry") }
          recovered = Sandcube::Reliability.new(db, runtime, capacity)
          expect_raises(Sandcube::ImageError) { recovered.request("POST", "/v1/sandboxes", body, nil) }
          recovered.reconcile
          id = recovered.request("POST", "/v1/sandboxes", body, "retry")["id"].as_s
          runtime.fault = "delete"
          expect_raises(IO::Error) { recovered.request("DELETE", "/v1/sandboxes/#{id}", nil, nil) }
          recovered.metrics.should contain("sandcube_allocated_disk_mb 32")
          recovered.reconcile
          recovered.metrics.should contain("sandcube_allocated_disk_mb 0")
          recovered.request("POST", "/v1/sandboxes", body, nil)["status"].as_s.should eq("running")
        end
      end
    end

    it "retains stopped storage until expiration cleanup succeeds and refuses unknown runtime capacity" do
      with_image_test_database(url) do |db|
        Sandcube::ImageStore.new(db)
        runtime = CrashRuntime.new
        manager = Sandcube::Reliability.new(db, runtime, Sandcube::Capacity.new(1_i64, 256_i64, 32_i64))
        body = %({"image":"test","command":["sleep"],"disk_mb":32})
        id = manager.request("POST", "/v1/sandboxes", body, nil)["id"].as_s
        manager.request("POST", "/v1/sandboxes/#{id}/stop", nil, nil)
        expect_raises(Sandcube::ImageError) { manager.request("POST", "/v1/sandboxes", body, nil) }
        db.exec("UPDATE sandboxes SET expires_at=now()-interval '1 second'")
        runtime.fault = "delete"
        manager.reconcile
        manager.metrics.should contain("sandcube_allocated_disk_mb 32")
        manager.reconcile
        manager.metrics.should contain("sandcube_allocated_disk_mb 0")
        runtime.containers["sbx_unknown"] = "running"
        expect_raises(Sandcube::ImageError, "unaccounted") { manager.request("POST", "/v1/sandboxes", body, nil) }
        manager.reconcile
        manager.request("POST", "/v1/sandboxes", body, nil)["status"].as_s.should eq("running")
      end
    end
  end
end
