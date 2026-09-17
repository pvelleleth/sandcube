require "spec"
require "../src/cli"

private def with_cli_dir(&block : String ->)
  dir = File.tempname(".sandcube-spec-", dir: Dir.current)
  Dir.mkdir(dir, 0o700)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def cli_config(data = "/mnt/sandcube")
  Sandcube::CLI::Config.new({
    "SANDCUBE_DATA_DIR" => data, "SANDCUBE_RUN_DIR" => "/run/sandcube",
    "SANDCUBE_HOST" => "127.0.0.1", "SANDCUBE_PORT" => "7432",
    "SANDCUBE_CAPACITY_CPU" => "2", "SANDCUBE_CAPACITY_MEMORY_MB" => "512",
    "SANDCUBE_CAPACITY_DISK_MB" => "1024",
  })
end

private def mount_json(path = "/mnt/sandcube", fs = "xfs", options = "rw,relatime,prjquota")
  {filesystems: [{target: path, fstype: fs, options: options}]}.to_json
end

describe Sandcube::CLI::Config do
  it "round trips local configuration with private permissions and refuses reinitialization" do
    with_cli_dir do |dir|
      config = cli_config(dir)
      path = File.join(dir, "config.env")
      config.save(path)
      (File.info(path).permissions.value & 0o777).should eq(0o600)
      # Load deliberately requires root, even if a non-root developer runs specs.
      if SandcubePosix.geteuid == 0
        Sandcube::CLI::Config.load(path).values.should eq(config.values)
        config.values.has_key?("DATABASE_URL").should be_false
        config.values.has_key?("SANDCUBE_API_KEY").should be_false
      end
      expect_raises(Exception, /already exists/) { config.save(path) }
    end
  end

  it "rejects world-readable config and symlink config" do
    with_cli_dir do |dir|
      path = File.join(dir, "config.env")
      cli_config(dir).save(path)
      File.chmod(path, 0o644)
      expect_raises(Exception, /0600/) { Sandcube::CLI::Config.load(path) }
      File.chmod(path, 0o600)
      File.symlink(path, path + ".link")
      expect_raises(Exception, /0600/) { Sandcube::CLI::Config.load(path + ".link") }
    end
  end

  it "rejects unsafe paths, invalid capacity and invalid bind addresses" do
    ["/", "relative", "/mnt", "/mnt/sand cube", "/mnt/evil\npath"].each do |path|
      expect_raises(ArgumentError) { Sandcube::CLI::Config.path!(path) }
    end
    config = cli_config
    config.values["SANDCUBE_CAPACITY_CPU"] = "0"
    expect_raises(ArgumentError, /positive/) { config.validate }
    config.values["SANDCUBE_CAPACITY_CPU"] = "1"
    config.values["SANDCUBE_RUN_DIR"] = "/mnt/sandcube/run"
    expect_raises(ArgumentError, /separate/) { config.validate }
    config.values["SANDCUBE_RUN_DIR"] = "/run/sandcube"
    config.values["SANDCUBE_HOST"] = "deadbeef"
    expect_raises(ArgumentError, /numeric IP/) { config.validate }
  end

  it "does not load the working directory's dotenv for CLI help/version" do
    Sandcube::CLI.run(["version"]).should eq(0)
    Sandcube::CLI.run(["serve", "--help"]).should eq(0)
    Sandcube::CLI.run(["unknown"]).should eq(1)
    Sandcube::CLI.run(["serve", "--enable-builds"]).should eq(1)
  end

  it "refuses legacy configuration before an empty SQLite journal can replace it" do
    config = cli_config
    config.values["DATABASE_URL"] = "legacy"
    expect_raises(ArgumentError, /Legacy PostgreSQL configuration/) { config.validate }
  end
end

describe Sandcube::CLI::Host do
  it "accepts an exact writable XFS project-quota mount" do
    Sandcube::CLI::Host.validate_mount(mount_json, "/mnt/sandcube")
    Sandcube::CLI::Host.validate_mount(mount_json(options: "rw,pquota"), "/mnt/sandcube")
  end

  it "fails closed for ext4, disabled enforcement, read-only mounts and subdirectories" do
    expect_raises(Exception, /XFS/) { Sandcube::CLI::Host.validate_mount(mount_json(fs: "ext4"), "/mnt/sandcube") }
    expect_raises(Exception, /prjquota/) { Sandcube::CLI::Host.validate_mount(mount_json(options: "rw,pqnoenforce"), "/mnt/sandcube") }
    expect_raises(Exception, /read-only/) { Sandcube::CLI::Host.validate_mount(mount_json(options: "ro,prjquota"), "/mnt/sandcube") }
    expect_raises(Exception, /dedicated mount/) { Sandcube::CLI::Host.validate_mount(mount_json, "/mnt/sandcube/subdir") }
    expect_raises(Exception, /dedicated mount/) { Sandcube::CLI::Host.validate_mount("{\"filesystems\":[]}", "/mnt/sandcube") }
  end
end

private class QuotaHost < Sandcube::CLI::Host
  def initialize(@path : String, @state : String)
  end

  def capture(command : String, args = [] of String) : String
    command == "findmnt" ? mount_json(@path) : @state
  end
end

describe "storage initialization" do
  it "checks active quota enforcement and refuses existing files" do
    with_cli_dir do |dir|
      expect_raises(Exception, /accounting and enforcement/) { QuotaHost.new(dir, "Accounting: ON\nEnforcement: OFF").storage!(dir) }
      host = QuotaHost.new(dir, "Accounting: ON\nEnforcement: ON")
      host.storage!(dir, empty: true)
      File.write(File.join(dir, "existing-data"), "keep me")
      expect_raises(Exception, /empty/) { host.storage!(dir, empty: true) }
      File.read(File.join(dir, "existing-data")).should eq("keep me")
    end
  end
end

private def make_bundle(path : String, corrupt = false, bad_name = false)
  entries = [] of Sandcube::CLI::Bundle::Entry
  File.open(path, "w") do |file|
    file << "ELF-fixture"
    Sandcube::CLI::Bundle::NAMES.each do |name|
      payload = "payload-#{name}\x00\xff"
      entries << Sandcube::CLI::Bundle::Entry.new(bad_name ? "../escape" : name, file.pos, payload.bytesize.to_i64,
        Digest::SHA256.hexdigest(corrupt ? "different" : payload))
      file << payload
    end
    manifest = Sandcube::CLI::Bundle::Manifest.new("0.1.0", entries).to_json
    file << manifest
    file.write_bytes(manifest.bytesize.to_u64, IO::ByteFormat::LittleEndian)
    file << Sandcube::CLI::Bundle::MAGIC
  end
end

describe Sandcube::CLI::Bundle do
  it "extracts binary bytes, verifies reused payloads and refuses tampering" do
    with_cli_dir do |dir|
      path = File.join(dir, "bundle")
      make_bundle(path)
      bundle = Sandcube::CLI::Bundle.new(path)
      extracted = bundle.extract(dir)
      bundle.extract(dir).should eq(extracted)
      api = File.join(extracted, "sandcube-api")
      File.read(api).should eq("payload-sandcube-api\x00\xff")
      (File.info(api).permissions.value & 0o777).should eq(0o700)
      File.write(api, "tampered")
      expect_raises(Exception, /Checksum mismatch/) { bundle.extract(dir) }
    end
  end

  it "rejects corrupt payloads without publishing an executable" do
    with_cli_dir do |dir|
      path = File.join(dir, "bundle")
      make_bundle(path, corrupt: true)
      expect_raises(Exception, /Checksum mismatch/) { Sandcube::CLI::Bundle.new(path).extract(dir) }
      Dir.glob(File.join(dir, "bin", "*", "*")).should be_empty
    end
  end

  it "rejects path traversal, truncated bundles and extraction through symlinks" do
    with_cli_dir do |dir|
      path = File.join(dir, "bundle")
      make_bundle(path, bad_name: true)
      expect_raises(Exception, /entries/) { Sandcube::CLI::Bundle.new(path) }
      File.write(path, "truncated")
      expect_raises(Exception, /No release payload/) { Sandcube::CLI::Bundle.new(path) }
      make_bundle(path)
      File.symlink(dir, File.join(dir, "bin"))
      expect_raises(Exception, /Unsafe directory/) { Sandcube::CLI::Bundle.new(path).extract(dir) }
    end
  end
end

describe Sandcube::CLI::RuntimeConfig do
  it "uses only private roots and writes BuildKit configuration" do
    config = cli_config
    toml = Sandcube::CLI::RuntimeConfig.containerd(config)
    toml.should contain("root = \"/mnt/sandcube/containerd\"")
    toml.should contain("state = \"/run/sandcube/containerd\"")
    toml.should contain("address = \"/run/sandcube/containerd.sock\"")
    Sandcube::CLI::RuntimeConfig.buildkit(config).should contain("networkMode = \"cni\"")
  end

  it "writes a CNI plugin list with the extension required by BuildKit" do
    with_cli_dir do |dir|
      config = cli_config(File.join(dir, "data"))
      config.values["SANDCUBE_RUN_DIR"] = dir
      Sandcube::CLI::RuntimeConfig.write(config)

      cni_path = File.join(dir, "buildkit-cni.conflist")
      File.read(File.join(dir, "buildkitd.toml")).should contain("cniConfigPath = #{cni_path.to_json}")
      cni = JSON.parse(File.read(cni_path))
      cni["plugins"].as_a.map { |plugin| plugin["type"].as_s }.should eq(["bridge", "firewall"])
      cni["plugins"][0]["ipam"]["dataDir"].as_s.should eq(File.join(config.data_dir, "cni"))
      (File.info(cni_path).permissions.value & 0o777).should eq(0o600)
    end
  end
end

private def fixture_child(supervisor, name, dir, script = "")
  ready = File.join(dir, "#{name}.ready")
  log = File.join(dir, "stopped")
  body = "trap 'echo #{name} >> \"$1\"; exit 0' TERM; #{script}\ntouch \"$2\"; while :; do sleep 0.02; done"
  supervisor.start(name, "/bin/sh", ["-c", body, "fixture", log, ready], {"PATH" => "/usr/bin:/bin"}, dir) { File.exists?(ready) }
end

describe Sandcube::CLI::Supervisor do
  it "handles real SIGINT and SIGTERM during startup and cleans up children" do
    {Signal::INT, Signal::TERM}.each do |signal|
      with_cli_dir do |dir|
        supervisor = Sandcube::CLI::Supervisor.new(2.seconds, 100.milliseconds)
        spawn do
          sleep 150.milliseconds
          Process.signal(signal, Process.pid)
        end
        supervisor.run do
          supervisor.start("starting", "/bin/sleep", ["30"], {} of String => String, dir) { false }
          fail "An interrupted startup must not start more children"
        end
        supervisor.children.size.should eq(1)
        supervisor.children.all?(&.status).should be_true
      end
    end
  end

  it "refuses occupied sockets and regular paths while recovering stale sockets" do
    with_cli_dir do |dir|
      path = File.join(dir, "test.sock")
      server = UNIXServer.new(path)
      expect_raises(Exception, /already in use/) { Sandcube::CLI::Supervisor.unused_socket!(path) }
      server.close
      # UNIXServer may unlink on close; recreate a stale socket with close-on-exec disabled cleanup.
      unless File.exists?(path)
        server = UNIXServer.new(path)
        File.rename(path, path + ".stale")
        server.close
        File.rename(path + ".stale", path)
      end
      Sandcube::CLI::Supervisor.unused_socket!(path)
      File.exists?(path).should be_false
      File.write(path, "keep me")
      expect_raises(Exception, /non-socket/) { Sandcube::CLI::Supervisor.unused_socket!(path) }
      File.read(path).should eq("keep me")
    end
  end

  it "starts in dependency order and shuts down in reverse order" do
    with_cli_dir do |dir|
      supervisor = Sandcube::CLI::Supervisor.new(2.seconds, 1.second)
      begin
        fixture_child(supervisor, "containerd", dir)
        fixture_child(supervisor, "runtime", dir)
        fixture_child(supervisor, "api", dir)
        supervisor.children.map(&.name).should eq(%w(containerd runtime api))
      ensure
        supervisor.shutdown
      end
      File.read(File.join(dir, "stopped")).lines.should eq(%w(api runtime containerd))
      supervisor.children.all?(&.status).should be_true
    end
  end

  it "reports an unexpected child exit and cleans up its dependencies" do
    with_cli_dir do |dir|
      supervisor = Sandcube::CLI::Supervisor.new(2.seconds, 1.second)
      begin
        fixture_child(supervisor, "containerd", dir)
        child = fixture_child(supervisor, "runtime", dir)
        child.signal(Signal::KILL)
        expect_raises(Exception, /runtime exited/) { supervisor.monitor }
      ensure
        supervisor.shutdown
      end
      supervisor.children.all?(&.status).should be_true
    end
  end

  it "times out readiness and escalates a child that ignores SIGTERM" do
    with_cli_dir do |dir|
      supervisor = Sandcube::CLI::Supervisor.new(150.milliseconds, 100.milliseconds)
      started = Time.instant
      begin
        expect_raises(Exception, /Timed out waiting/) do
          supervisor.start("stuck", "/bin/sh", ["-c", "trap '' TERM; exec sleep 30"], {"PATH" => "/bin:/usr/bin"}, dir) { false }
        end
      ensure
        supervisor.shutdown
      end
      (Time.instant - started).should be < 3.seconds
      supervisor.children.first.status.not_nil!.exit_signal?.should eq(Signal::KILL)
    end
  end

  it "aborts startup on early child exit and on an interrupt" do
    with_cli_dir do |dir|
      supervisor = Sandcube::CLI::Supervisor.new(2.seconds, 100.milliseconds)
      begin
        expect_raises(Exception, /exited/) do
          supervisor.start("failure", "/bin/sh", ["-c", "exit 7"], {} of String => String, dir) { false }
        end
      ensure
        supervisor.shutdown
      end
      supervisor.children.first.status.not_nil!.exit_code.should eq(7)
      expect_raises(Exception, /interrupted/) { supervisor.check! }
    end
  end

  it "probes HTTP health rather than just the existence of a socket" do
    Sandcube::CLI::Supervisor.http_ready("/does-not-exist/runtime.sock").should be_false
    Sandcube::CLI::Supervisor.command_ready("/bin/false", [] of String).should be_false
    Sandcube::CLI::Supervisor.command_ready("/bin/true", [] of String).should be_true
  end
end
