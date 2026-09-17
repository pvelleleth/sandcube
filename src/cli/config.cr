require "json"
require "uri"
require "random/secure"
require "file_utils"
require "socket"

lib SandcubePosix
  fun geteuid : UInt32
end

module Sandcube::CLI
  # JSON-quoted dotenv values are parsed as data, never evaluated by a shell.
  class Config
    getter values : Hash(String, String)

    def initialize(@values = {} of String => String)
    end

    def [](key : String) : String
      @values[key]? || raise ArgumentError.new("Missing #{key}; run sandcube init")
    end

    def data_dir : String
      self["SANDCUBE_DATA_DIR"]
    end

    def run_dir : String
      self["SANDCUBE_RUN_DIR"]
    end

    def self.path!(path : String) : String
      raise ArgumentError.new("Use an absolute path containing only letters, digits, /, _, - and .") unless path.matches?(/\A\/[a-zA-Z0-9\/_.-]+\z/)
      path = File.expand_path(path)
      raise ArgumentError.new("A dedicated directory is required") if {"/", "/var", "/var/lib", "/run", "/mnt", "/etc", "/usr", "/root"}.includes?(path)
      path
    end

    def validate : Nil
      if @values.has_key?("DATABASE_URL")
        raise ArgumentError.new("Legacy PostgreSQL configuration: export or retire existing sandboxes, then run init with a fresh config and data directory (see docs/installation.md)")
      end
      self.class.path!(data_dir)
      self.class.path!(run_dir)
      raise ArgumentError.new("Runtime directory is too long for Unix sockets (maximum 60 bytes)") if run_dir.bytesize > 60
      raise ArgumentError.new("Data and runtime directories must be separate") if data_dir == run_dir || data_dir.starts_with?(run_dir + "/") || run_dir.starts_with?(data_dir + "/")
      if image = @values["SANDCUBE_STORAGE_IMAGE"]?
        self.class.path!(image)
        raise ArgumentError.new("Storage image must be outside its mount") if image.starts_with?(data_dir + "/")
      end
      %w(SANDCUBE_CAPACITY_CPU SANDCUBE_CAPACITY_MEMORY_MB SANDCUBE_CAPACITY_DISK_MB).each do |key|
        raise ArgumentError.new("#{key} must be positive") unless self[key].to_i64?.try { |n| n > 0 }
      end
      raise ArgumentError.new("Invalid port") unless self["SANDCUBE_PORT"].to_i?.try { |n| (1..65535).includes?(n) }
      raise ArgumentError.new("Host must be a numeric IP address") unless Socket::IPAddress.valid?(self["SANDCUBE_HOST"])
      @values.each_value { |v| raise ArgumentError.new("Configuration cannot contain control characters") if v.matches?(/[\x00-\x1f]/) }
    end

    def self.load(path : String) : Config
      info = File.info(path, follow_symlinks: false)
      raise "Config must be a root-owned regular file with mode 0600: #{path}" unless info.file? && info.owner_id == "0" && info.permissions.value & 0o7777 == 0o600
      values = {} of String => String
      File.each_line(path) do |line|
        next if line.empty? || line.starts_with?('#')
        key, _, raw = line.partition('=')
        raise "Invalid config key" unless key.matches?(/\A[A-Z][A-Z0-9_]*\z/) && !values.has_key?(key)
        values[key] = String.from_json(raw)
      end
      config = new(values)
      config.validate
      config
    end

    def save(path : String) : Nil
      validate
      raise "Config already exists: #{path}; edit it deliberately to change an initialized host" if File.exists?(path) || File.symlink?(path)
      file = File.tempfile(".config-", dir: File.dirname(path))
      begin
        @values.each { |key, value| file.puts "#{key}=#{value.to_json}" }
        file.flush
        file.fsync
        File.link(file.path, path) # atomic publication; never replaces existing config
      ensure
        file.close
        file.delete
      end
    end
  end

  # Refuse symlinks and directories writable by other users before root writes.
  def self.private_dir(path : String) : Nil
    parent = File.dirname(path)
    private_parent(parent) unless parent == path
    Dir.mkdir(path, 0o700) unless File.exists?(path) || File.symlink?(path)
    info = File.info(path, follow_symlinks: false)
    raise "Unsafe directory: #{path}" unless info.directory? && info.owner_id == SandcubePosix.geteuid.to_s && info.permissions.value & 0o022 == 0
    File.chmod(path, 0o700)
  end

  def self.private_parent(path : String) : Nil
    info = File.info(path, follow_symlinks: false)
    raise "Unsafe parent directory: #{path}" unless info.directory? && {"0", SandcubePosix.geteuid.to_s}.includes?(info.owner_id) && info.permissions.value & 0o022 == 0
    parent = File.dirname(path)
    private_parent(parent) unless parent == path
  end
end
