module Sandcube
  # Allocatable budgets exclude the OS, runtime overhead, images, builds and logs.
  # Production requires explicit budgets; constructor defaults keep embedded tests simple.
  record Capacity, cpu : Int64 = 64_i64, memory_mb : Int64 = 262144_i64, disk_mb : Int64 = 1048576_i64 do
    def self.from_env
      value = new(ENV.fetch("SANDCUBE_CAPACITY_CPU").to_i64,
        ENV.fetch("SANDCUBE_CAPACITY_MEMORY_MB").to_i64,
        ENV.fetch("SANDCUBE_CAPACITY_DISK_MB").to_i64)
      raise ArgumentError.new("Capacity budgets must be positive") unless value.cpu > 0 && value.memory_mb > 0 && value.disk_mb > 0
      value
    end

    def configure(conn)
      conn.exec("INSERT INTO host_capacity(singleton,cpu,memory_mb,disk_mb) VALUES(1,?1,?2,?3) ON CONFLICT DO NOTHING", @cpu, @memory_mb, @disk_mb)
      saved = conn.query_one("SELECT cpu,memory_mb,disk_mb FROM host_capacity WHERE singleton", as: {Int64, Int64, Int64})
      raise ArgumentError.new("Capacity configuration differs from the host's persisted budgets") unless saved == {@cpu, @memory_mb, @disk_mb}
    end

    # Called inside the host lock AND the intent transaction. Uncertain cleanup
    # retains its reservation; a process crash cannot make capacity disappear.
    def reserve(conn, id, cpu, memory, disk)
      used = conn.query_one("SELECT COALESCE(sum(reserved_cpu),0), COALESCE(sum(reserved_memory_mb),0), COALESCE(sum(reserved_disk_mb),0) FROM sandboxes WHERE id!=?1", id, as: {Int64, Int64, Int64})
      if cpu > @cpu - used[0] || memory > @memory_mb - used[1] || disk > @disk_mb - used[2]
        raise ImageError.new(409, "INSUFFICIENT_CAPACITY", "Host CPU, memory or writable-storage capacity is exhausted")
      end
      conn.exec("UPDATE sandboxes SET reserved_cpu=?2,reserved_memory_mb=?3,reserved_disk_mb=?4 WHERE id=?1", id, cpu, memory, disk)
    end
  end
end
