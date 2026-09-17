require "http/client"
require "socket"
require "./config"

module Sandcube::CLI
  class Child
    getter name : String
    getter process : Process
    property status : Process::Status?

    def initialize(@name, command : String, args : Array(String), env : Hash(String, String), directory : String)
      @process = Process.new(command, args, env: env, clear_env: true, chdir: directory,
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      spawn { @status = @process.wait }
    end

    def signal(signal : Signal)
      @process.signal(signal) unless @status
    rescue IO::Error
      # The waiter may not have observed a concurrent exit yet.
    end
  end

  class Supervisor
    getter children = [] of Child
    property stopping = false

    def initialize(@timeout = 60.seconds, @grace = 15.seconds)
    end

    def run(&block : ->) : Nil
      Signal::INT.trap { @stopping = true }
      Signal::TERM.trap { @stopping = true }
      begin
        yield
        monitor
      rescue ex
        raise ex unless @stopping
      ensure
        shutdown
        Signal::INT.reset
        Signal::TERM.reset
      end
    end

    def check! : Nil
      raise "Startup interrupted" if @stopping
      @children.each do |child|
        if status = child.status
          raise "#{child.name} exited (#{status}); stopping the service"
        end
      end
    end

    def start(name : String, command : String, args : Array(String), env : Hash(String, String), directory : String, &ready : -> Bool) : Child
      check!
      child = Child.new(name, command, args, env, directory)
      @children << child
      deadline = Time.instant + @timeout
      loop do
        check!
        if ready.call
          Fiber.yield
          check!
          puts "sandcube: #{name} ready"
          return child
        end
        raise "Timed out waiting for #{name}" if Time.instant >= deadline
        sleep 100.milliseconds
      end
    end

    def monitor : Nil
      until @stopping
        check!
        sleep 100.milliseconds
      end
    end

    def shutdown : Nil
      @stopping = true
      # Dependents finish first, while their runtime/database dependencies still exist.
      @children.reverse_each do |child|
        child.signal(Signal::TERM)
        deadline = Time.instant + @grace
        until child.status || Time.instant >= deadline
          sleep 20.milliseconds
        end
        unless child.status
          child.signal(Signal::KILL)
          until child.status
            sleep 20.milliseconds
          end
        end
      end
    end

    def self.command_ready(command : String, args : Array(String)) : Bool
      process = Process.new(command, args, clear_env: true, env: {"PATH" => ENV.fetch("PATH", "/usr/bin:/bin")})
      status = nil.as(Process::Status?)
      spawn { status = process.wait }
      deadline = Time.instant + 2.seconds
      until status || Time.instant >= deadline
        sleep 20.milliseconds
      end
      unless status
        process.signal(Signal::KILL) rescue nil
        until status
          sleep 10.milliseconds
        end
      end
      status.not_nil!.success?
    rescue IO::Error
      false
    end

    def self.http_ready(socket : String? = nil, host = "127.0.0.1", port = 7432) : Bool
      client = socket ? HTTP::Client.new(connect_unix(socket)) : HTTP::Client.new(host, port)
      client.connect_timeout = 1.second
      client.read_timeout = 1.second
      client.write_timeout = 1.second
      client.get("/health").success?
    rescue IO::Error | Socket::Error
      false
    ensure
      client.try(&.close)
    end

    private def self.connect_unix(path : String) : Socket
      socket = Socket.new(Socket::Family::UNIX, Socket::Type::STREAM)
      begin
        socket.connect(Socket::UNIXAddress.new(path), 1.second)
        socket
      rescue ex
        socket.close
        raise ex
      end
    end

    def self.unused_socket!(path : String) : Nil
      return unless File.exists?(path) || File.symlink?(path)
      raise "Refusing non-socket path: #{path}" unless File.info(path, follow_symlinks: false).type.socket?
      connected = begin
        connect_unix(path).close
        true
      rescue Socket::ConnectError
        false
      end
      raise "Socket is already in use: #{path}; stop its owning service first" if connected
      # The lifetime locks are held; only remove a proven stale socket inode.
      File.delete(path)
    end
  end

  module RuntimeConfig
    def self.systemd(config : Config, path : String) : String
      <<-UNIT
      [Unit]
      RequiresMountsFor=#{config.data_dir}
      ConditionPathExists=
      ConditionPathExists=#{path}
      [Service]
      ExecStart=
      ExecStart=/usr/local/bin/sandcube serve --config #{path}
      UNIT
    end

    def self.containerd(config : Config) : String
      <<-TOML
      version = 3
      root = #{File.join(config.data_dir, "containerd").to_json}
      state = #{File.join(config.run_dir, "containerd").to_json}
      disabled_plugins = ["io.containerd.grpc.v1.cri", "io.containerd.cri.v1.images", "io.containerd.cri.v1.runtime"]
      [grpc]
        address = #{File.join(config.run_dir, "containerd.sock").to_json}
        uid = 0
        gid = 0
      TOML
    end

    def self.buildkit(config : Config) : String
      <<-TOML
      root = #{File.join(config.data_dir, "buildkit").to_json}
      [grpc]
        address = [#{("unix://" + File.join(config.run_dir, "buildkitd.sock")).to_json}]
        uid = 0
        gid = 0
      [worker.oci]
        enabled = true
        snapshotter = "overlayfs"
        networkMode = "cni"
        cniConfigPath = #{File.join(config.run_dir, "buildkit-cni.conflist").to_json}
        cniBinaryPath = "/opt/cni/bin"
      [worker.containerd]
        enabled = false
      TOML
    end

    def self.write(config : Config)
      files = {"containerd.toml" => containerd(config), "runsc.toml" => {{ read_file("#{__DIR__}/../../infra/gvisor/runsc.toml") }}}
      files["buildkitd.toml"] = buildkit(config)
      # BuildKit selects the plugin-list parser by the .conflist extension.
      cni = JSON.parse({{ read_file("#{__DIR__}/../../infra/buildkit/buildkit-cni.conflist") }})
      cni["plugins"][0]["ipam"].as_h["dataDir"] = JSON::Any.new(File.join(config.data_dir, "cni"))
      files["buildkit-cni.conflist"] = cni.to_json
      files.each do |name, content|
        path = File.join(config.run_dir, name)
        raise "Refusing symlink: #{path}" if File.symlink?(path)
        File.write(path, content, perm: 0o600)
      end
    end
  end
end
