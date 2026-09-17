require "json"
require "socket"
require "./config"

module Sandcube::CLI
  class Host
    BASE_COMMANDS = %w(containerd ctr runsc containerd-shim-runsc-v1 ip nft conntrack sysctl findmnt xfs_quota xfs_info mkfs.xfs mount umount mountpoint losetup fallocate modprobe)

    def dependencies_ready? : Bool
      commands = BASE_COMMANDS + %w(buildkitd buildctl runc iptables)
      return false unless commands.all? { |command| Process.find_executable(command) }
      return false unless %w(bridge host-local loopback firewall).all? { |name| File::Info.executable?("/opt/cni/bin/#{name}") }
      version = capture("containerd", ["--version"]).match(/\bv?(\d+)\.(\d+)\./)
      !!(version && version[1] == "2" && version[2].to_i >= 2)
    rescue
      false
    end

    # A preallocated image preserves project quotas on ordinary ext4 VPS disks
    # without repartitioning or formatting any existing block device.
    def provision_storage(path : String, image : String, requested_size : Int64? = nil) : Nil
      CLI.private_dir(path)
      raise "Storage directory must be empty" unless Dir.children(path).empty?
      raise "Managed storage path is already mounted; use --storage for a custom mount" if Process.run("mountpoint", ["-q", path]).success?
      raise "Storage image already exists: #{image}" if File.exists?(image) || File.symlink?(image)
      available = capture("df", ["-BM", "--output=avail", File.dirname(image)]).lines.last.strip.rstrip('M').to_i64
      size = requested_size || available * 3 // 4
      raise "Storage image must be at least 512 MiB and leave 256 MiB free" unless size >= 512 && size <= available - 256
      temporary = File.tempfile(".storage-", dir: File.dirname(image))
      begin
        capture("fallocate", ["-l", "#{size}M", temporary.path])
        capture("mkfs.xfs", ["-q", "-K", temporary.path])
        temporary.fsync
        File.link(temporary.path, image)
      ensure
        temporary.close
        temporary.delete
      end
      mount_storage(Config.new({"SANDCUBE_DATA_DIR" => path, "SANDCUBE_STORAGE_IMAGE" => image}))
      storage!(path, empty: true)
    end

    def mount_storage(config : Config) : Nil
      image = config.values["SANDCUBE_STORAGE_IMAGE"]?
      return unless image
      CLI.private_dir(File.dirname(image))
      info = File.info(image, follow_symlinks: false)
      raise "Unsafe storage image: #{image}" unless info.file? && info.owner_id == "0" && info.permissions.value & 0o077 == 0
      # Never hide existing files behind the managed mount.
      unless Process.run("mountpoint", ["-q", config.data_dir]).success?
        CLI.private_dir(config.data_dir)
        raise "Managed mount directory is not empty" unless Dir.children(config.data_dir).empty?
        capture("mount", ["-o", "loop,prjquota", image, config.data_dir])
      end
      source = capture("findmnt", ["-n", "-o", "SOURCE", "--mountpoint", config.data_dir])
      backing = capture("losetup", ["--noheadings", "--raw", "--output", "BACK-FILE", source])
      raise "Storage mount does not use the configured image" unless backing == image
      storage!(config.data_dir)
    end

    def prepare_kernel : Nil
      capture("modprobe", ["overlay"]) unless File.read("/proc/filesystems").includes?("overlay")
      capture("sysctl", ["-w", "net.ipv4.ip_forward=1"])
    end

    def capture(command : String, args = [] of String) : String
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(command, args, output: output, error: error, clear_env: true,
        env: {"LC_ALL" => "C", "PATH" => ENV.fetch("PATH", "/usr/bin:/bin")})
      raise "#{command} failed: #{error}" unless status.success?
      output.to_s.strip
    end

    def self.validate_mount(json : String, path : String) : Nil
      mounts = JSON.parse(json)["filesystems"].as_a
      raise "Storage must be a dedicated mount point: #{path}" unless mounts.size == 1 && mounts[0]["target"].as_s == path
      mount = mounts[0]
      raise "Storage must be XFS; prepare and mount an empty XFS filesystem yourself" unless mount["fstype"].as_s == "xfs"
      options = mount["options"].as_s.split(',')
      raise "Mount XFS with prjquota (project quota enforcement)" unless options.includes?("prjquota") || options.includes?("pquota")
      raise "Storage is mounted read-only" unless options.includes?("rw")
    end

    def storage!(path : String, empty = false) : Nil
      raise "Storage cannot be a symlink" if File.symlink?(path)
      self.class.validate_mount(capture("findmnt", ["--json", "--mountpoint", path, "--output", "TARGET,FSTYPE,OPTIONS"]), path)
      # Mount options alone are insufficient if enforcement was subsequently disabled.
      state = capture("xfs_quota", ["-x", "-c", "state -p", path])
      raise "Enable XFS project quota accounting and enforcement" unless state.includes?("Accounting: ON") && state.includes?("Enforcement: ON")
      raise "Storage must be empty for first initialization" if empty && !Dir.children(path).empty?
    end

    def defaults(data : String, run : String) : Config
      cpu = capture("getconf", ["_NPROCESSORS_ONLN"]).to_i64
      memory = File.read("/proc/meminfo").match(/^MemTotal:\s+(\d+)/m).not_nil![1].to_i64 // 1024
      existing = data
      until Dir.exists?(existing)
        existing = File.dirname(existing)
      end
      disk = capture("df", ["-BM", "--output=avail", existing]).lines.last.strip.rstrip('M').to_i64
      Config.new({
        "SANDCUBE_DATA_DIR" => data, "SANDCUBE_RUN_DIR" => run,
        "SANDCUBE_HOST" => "127.0.0.1", "SANDCUBE_PORT" => "7432",
        "SANDCUBE_CAPACITY_CPU" => Math.max(1_i64, cpu - 1).to_s,
        "SANDCUBE_CAPACITY_MEMORY_MB" => Math.max(1_i64, memory * 3 // 4).to_s,
        "SANDCUBE_CAPACITY_DISK_MB" => Math.max(1_i64, disk * 3 // 4).to_s,
      })
    end

    def doctor(config : Config, output : IO = STDOUT) : Bool
      failures = 0
      checks = {
        "Linux/root"      => -> { raise "Run as root on Linux" unless SandcubePosix.geteuid == 0 && File.exists?("/proc/sys/kernel/ostype") },
        "XFS storage"     => -> { storage!(config.data_dir) },
        "cgroup v2"       => -> { raise "Boot with cgroup v2 enabled" unless File.exists?("/sys/fs/cgroup/cgroup.controllers") },
        "IPv4 forwarding" => -> { raise "Set net.ipv4.ip_forward=1 using sysctl" unless File.read("/proc/sys/net/ipv4/ip_forward").strip == "1" },
        "overlayfs"       => -> { raise "Load overlayfs: modprobe overlay" unless File.read("/proc/filesystems").includes?("overlay") },
        "kernel 5.6+"     => -> {
          version = capture("uname", ["-r"]).match(/\A(\d+)\.(\d+)/)
          raise "gVisor requires Linux 5.6 or newer" unless version && (version[1].to_i > 5 || (version[1] == "5" && version[2].to_i >= 6))
        },
        "cgroup controllers" => -> {
          available = File.read("/sys/fs/cgroup/cgroup.controllers").split
          raise "Enable cpu, memory and pids cgroup v2 controllers" unless %w(cpu memory pids).all? { |name| available.includes?(name) }
        },
        "XFS overlay support" => -> {
          raise "XFS must use ftype=1 for overlayfs snapshots" unless capture("xfs_info", [config.data_dir]).includes?("ftype=1")
        },
        "gVisor executable" => -> { capture("runsc", ["--version"]); nil },
        "containerd 2.2+"   => -> {
          version = capture("containerd", ["--version"]).match(/\bv?(\d+)\.(\d+)\./)
          raise "Install containerd 2.2 or later (major version 2)" unless version && version[1] == "2" && version[2].to_i >= 2
        },
      }
      checks.each do |name, check|
        begin
          check.call
          output.puts "OK   #{name}"
        rescue ex
          failures += 1
          output.puts "FAIL #{name}: #{ex.message}"
        end
      end
      commands = BASE_COMMANDS + %w(buildkitd buildctl runc iptables)
      commands.each do |command|
        if Process.find_executable(command)
          output.puts "OK   #{command}"
        else
          failures += 1
          output.puts "FAIL #{command}: rerun the installer"
        end
      end
      %w(bridge host-local loopback firewall).each do |plugin|
        unless File::Info.executable?("/opt/cni/bin/#{plugin}")
          failures += 1
          output.puts "FAIL CNI #{plugin}: rerun the installer"
        end
      end
      failures == 0
    end
  end
end
