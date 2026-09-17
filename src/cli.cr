require "option_parser"
require "./cli/config"
require "./cli/host"
require "./cli/bundle"
require "./cli/supervisor"
require "./database"
require "./capacity"

module Sandcube::CLI
  VERSION        = {{ read_file("#{__DIR__}/../shard.yml").split("version: ")[1].split('\n')[0] }}
  DEFAULT_CONFIG = "/var/lib/sandcube/config.env"
  SAFE_PATH      = "/usr/local/lib/sandcube/deps/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  def self.run(args = ARGV) : Int32
    command = args.shift? || "help"
    if {"help", "--help", "-h"}.includes?(command)
      puts "Usage: sandcube <init|doctor|serve|version> [options]\nRun sandcube <command> --help for options."
      return 0
    end
    if {"version", "--version"}.includes?(command)
      raise "version takes no arguments" unless args.empty?
      version = begin
        Bundle.new.manifest.version
      rescue
        VERSION
      end
      puts "sandcube #{version}"
      return 0
    end
    raise "Unknown command: #{command}" unless {"init", "doctor", "serve"}.includes?(command)
    config_path = DEFAULT_CONFIG
    storage = ""
    storage_size = nil.as(Int64?)
    runtime = "/run/sandcube"
    overrides = {} of String => String
    help = false
    parser = OptionParser.new do |p|
      p.banner = "Usage: sandcube #{command} [options]"
      p.on("--config PATH", "Config file (default #{DEFAULT_CONFIG})") { |v| config_path = Config.path!(v) }
      if command == "init"
        p.on("--storage PATH", "Empty XFS mount with prjquota; all persistent state lives here") { |v| storage = Config.path!(v) }
        p.on("--storage-size-mb N", "Managed storage image size (default 75% of free disk)") { |v| storage_size = v.to_i64 }
        p.on("--run-dir PATH", "Private sockets (default /run/sandcube)") { |v| runtime = Config.path!(v) }
        p.on("--capacity-cpu N", "Allocatable whole vCPUs") { |v| overrides["SANDCUBE_CAPACITY_CPU"] = v }
        p.on("--capacity-memory-mb N", "Allocatable memory MiB") { |v| overrides["SANDCUBE_CAPACITY_MEMORY_MB"] = v }
        p.on("--capacity-disk-mb N", "Allocatable writable storage MiB") { |v| overrides["SANDCUBE_CAPACITY_DISK_MB"] = v }
        p.on("--host IP", "HTTP bind address (default 127.0.0.1)") { |v| overrides["SANDCUBE_HOST"] = v }
        p.on("--port N", "HTTP port (default 7432)") { |v| overrides["SANDCUBE_PORT"] = v }
      end
      p.on("-h", "--help", "Show help") { puts p; help = true }
      p.invalid_option { |flag| raise "Unknown option: #{flag}" }
      p.unknown_args { |remaining| raise "Unexpected arguments: #{remaining.join(' ')}" unless remaining.empty? }
    end
    parser.parse(args)
    return 0 if help
    raise "Run sandcube #{command} as root" unless SandcubePosix.geteuid == 0
    ENV["PATH"] = SAFE_PATH
    host = Host.new
    if command == "init"
      raise "--storage-size-mb applies only to managed storage" if !storage.empty? && storage_size
      raise "Storage image must be at least 512 MiB" if storage_size.try { |size| size < 512 }
      raise "Already initialized: #{config_path}" if File.exists?(config_path) || File.symlink?(config_path)
      managed = storage.empty?
      storage = File.join(File.dirname(config_path), "data") if managed
      # Reject invalid addresses, paths and budgets before provisioning storage.
      planned = host.defaults(storage, runtime)
      planned.values.merge!(overrides)
      planned.validate
      File.open("/run/sandcube-init.lock", "a", perm: 0o600) do |lock|
        lock.flock_exclusive(blocking: false)
        raise "Already initialized: #{config_path}" if File.exists?(config_path)
        private_dir(File.dirname(config_path))
        unless host.dependencies_ready?
          staging = "/run/sandcube-install-#{Random::Secure.hex(8)}"
          private_dir(staging)
          begin
            binaries = Bundle.new.extract(staging)
            raise "Dependency installation failed" unless Process.run("/bin/sh", [File.join(binaries, "install-deps.sh")], output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).success?
          ensure
            FileUtils.rm_rf(staging)
          end
        end
        image = File.join(File.dirname(config_path), "storage.xfs")
        if managed
          host.provision_storage(storage, image, storage_size)
        else
          host.storage!(storage, empty: true)
        end
        private_dir(storage)
        host.prepare_kernel
        config = host.defaults(storage, runtime)
        config.values["SANDCUBE_STORAGE_IMAGE"] = image if managed
        config.values.merge!(overrides)
        config.validate
        raise "Host prerequisites failed" unless host.doctor(config)
        db = Sandcube::Database.open(File.join(storage, "sandcube.db"))
        db.using_connection do |conn|
          Sandcube::Capacity.new(config["SANDCUBE_CAPACITY_CPU"].to_i64,
            config["SANDCUBE_CAPACITY_MEMORY_MB"].to_i64, config["SANDCUBE_CAPACITY_DISK_MB"].to_i64).configure(conn)
        end
        db.close
        config.save(config_path)
        if File.exists?("/etc/systemd/system/sandcube.service")
          private_dir("/etc/systemd/system/sandcube.service.d")
          File.write("/etc/systemd/system/sandcube.service.d/storage.conf", RuntimeConfig.systemd(config, config_path), perm: 0o600)
          raise "Config saved, but systemctl daemon-reload failed" unless Process.run("systemctl", ["daemon-reload"]).success?
        end
      end
      config = Config.load(config_path)
      puts "Initialized #{storage}; local SQLite database: #{storage}/sandcube.db"
      puts "Capacity: #{config["SANDCUBE_CAPACITY_CPU"]} vCPU, #{config["SANDCUBE_CAPACITY_MEMORY_MB"]} MiB memory, #{config["SANDCUBE_CAPACITY_DISK_MB"]} MiB disk."
      suffix = config_path == DEFAULT_CONFIG ? "" : " --config #{config_path}"
      puts "Run sandcube serve#{suffix}."
      return 0
    end
    config = Config.load(config_path)
    if command == "serve"
      host.mount_storage(config)
      host.prepare_kernel
    end
    healthy = host.doctor(config)
    return healthy ? 0 : 1 if command == "doctor"
    raise "Host prerequisites failed; see sandcube doctor" unless healthy
    serve(config)
    0
  rescue ex
    message = ex.message || ex.class.to_s
    STDERR.puts "sandcube: #{message}"
    1
  end

  def self.serve(config : Config) : Nil
    private_dir(config.data_dir)
    private_dir(config.run_dir)
    File.open(File.join(config.data_dir, "serve.lock"), "a", perm: 0o600) do |data_lock|
      data_lock.flock_exclusive(blocking: false)
      File.open(File.join(config.run_dir, "serve.lock"), "a", perm: 0o600) do |run_lock|
        run_lock.flock_exclusive(blocking: false)
        binaries = Bundle.new.extract(config.data_dir)
        %w(containerd process-history builds tmp).each { |name| private_dir(File.join(config.data_dir, name)) }
        private_dir(File.join(config.run_dir, "containerd"))
        %w(containerd.sock runtime.sock buildkitd.sock).each { |name| Supervisor.unused_socket!(File.join(config.run_dir, name)) }
        TCPServer.new(config["SANDCUBE_HOST"], config["SANDCUBE_PORT"].to_i).close
        RuntimeConfig.write(config)
        supervisor = Supervisor.new
        env = {"PATH" => SAFE_PATH, "HOME" => config.data_dir, "TMPDIR" => File.join(config.data_dir, "tmp")}
        supervisor.run do
          address = File.join(config.run_dir, "containerd.sock")
          supervisor.start("containerd", "containerd", ["--config", File.join(config.run_dir, "containerd.toml")], env, config.data_dir) do
            Supervisor.command_ready("ctr", ["--address", address, "version"])
          end
          socket = File.join(config.run_dir, "runtime.sock")
          supervisor.start("runtime", File.join(binaries, "containerd-runtime"), [
            "-socket", socket, "-containerd", address, "-containerd-state", File.join(config.run_dir, "containerd"),
            "-runsc-config", File.join(config.run_dir, "runsc.toml"), "-history-root", File.join(config.data_dir, "process-history"),
            "-build-root", File.join(config.data_dir, "builds"),
          ], env, config.data_dir) { Supervisor.http_ready(socket) }
          build_address = "unix://" + File.join(config.run_dir, "buildkitd.sock")
          supervisor.start("buildkit", "buildkitd", ["--config", File.join(config.run_dir, "buildkitd.toml")], env, config.data_dir) do
            Supervisor.command_ready("buildctl", ["--addr", build_address, "debug", "workers"])
          end
          api_env = env.merge(config.values).merge({
            "SANDCUBE_RUNTIME_SOCKET" => socket, "SANDCUBE_BUILD_ROOT" => File.join(config.data_dir, "builds"),
            "SANDCUBE_BUILDKIT_ADDRESS" => "unix://" + File.join(config.run_dir, "buildkitd.sock"),
            "SANDCUBE_IMAGE_API_ENABLED" => "true", "SANDCUBE_MANAGED" => "true",
          })
          probe_host = config["SANDCUBE_HOST"]
          probe_host = "127.0.0.1" if probe_host == "0.0.0.0"
          probe_host = "::1" if probe_host == "::"
          supervisor.start("api", File.join(binaries, "sandcube-api"), [] of String, api_env, config.data_dir) do
            Supervisor.http_ready(host: probe_host, port: config["SANDCUBE_PORT"].to_i)
          end
          puts "sandcube: serving on #{config["SANDCUBE_HOST"]}:#{config["SANDCUBE_PORT"]}"
        end
      end
    end
  end
end
