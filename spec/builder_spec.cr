require "spec"
require "../src/service"

class ImportTestRuntime < Sandcube::Runtime
  getter calls = [] of Tuple(String, String, String?)
  property failure = false

  def request(method : String, path : String, body : String? = nil) : JSON::Any
    @calls << {method, path, body}
    raise IO::Error.new("import unavailable") if failure
    JSON.parse(%({"oci_digest":"sha256:test"}))
  end
end

describe Sandcube::BuildKitImageBuilder do
  it "passes arguments literally, clears host environment, and imports only after success" do
    with_context do |directory|
      binary = File.join(directory, "fake-buildctl")
      File.write(binary, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HOME/args\"\nprintf '%s' \"${SANDCUBE_TEST_SECRET-unset}\" > \"$HOME/env\"\n")
      File.chmod(binary, 0o700)
      runtime = ImportTestRuntime.new
      ENV["SANDCUBE_TEST_SECRET"] = "must-not-reach-builder"
      begin
        builder = Sandcube::BuildKitImageBuilder.new(runtime, "unix:///private.sock", binary)
        builder.build(directory, "sandcube.local/images/img_test:latest", {"VALUE" => "$(touch #{directory}/injected); spaces"})
        File.exists?("#{directory}/injected").should be_false
        File.read("#{directory}/env").should eq("unset")
        File.read("#{directory}/args").should contain("build-arg:VALUE=$(touch #{directory}/injected); spaces")
        runtime.calls.size.should eq(1)
        runtime.calls[0][1].should eq("/images/import")
        JSON.parse(runtime.calls[0][2].not_nil!)["path"].as_s.should eq("#{directory}/image.tar")
      ensure
        ENV.delete("SANDCUBE_TEST_SECRET")
      end
    end
  end
  it "never imports failed builds and bounds captured diagnostics" do
    with_context do |directory|
      binary = File.join(directory, "fake-buildctl")
      File.write(binary, "#!/bin/sh\nhead -c 100000 /dev/zero | tr '\\000' x\nexit 23\n")
      File.chmod(binary, 0o700)
      runtime = ImportTestRuntime.new
      builder = Sandcube::BuildKitImageBuilder.new(runtime, "unix:///private.sock", binary)
      ex = expect_raises(Sandcube::ImageError) { builder.build(directory, "test", {} of String => String) }
      ex.message.not_nil!.bytesize.should be < 66000
      ex.message.not_nil!.should contain("exited 23")
      runtime.calls.should be_empty
    end
  end
  it "terminates timed-out builds without importing" do
    with_context do |directory|
      binary = File.join(directory, "fake-buildctl")
      File.write(binary, "#!/bin/sh\nsleep 30\n")
      File.chmod(binary, 0o700)
      runtime = ImportTestRuntime.new
      builder = Sandcube::BuildKitImageBuilder.new(runtime, "unix:///private.sock", binary, 1)
      started = Time.instant
      expect_raises(Sandcube::ImageError) { builder.build(directory, "test", {} of String => String) }
      (Time.instant - started).should be < 5.seconds
      runtime.calls.should be_empty
    end
  end
end
