require "spec"
require "../src/service"

class FakeRuntime < Sandcube::Runtime
  getter calls = [] of Tuple(String, String, String?)
  property fail_start = false
  property unavailable = false

  def request(method : String, path : String, body : String? = nil) : JSON::Any
    @calls << {method, path, body}
    raise IO::Error.new("offline") if unavailable
    raise Sandcube::RuntimeError.new(500, %({"error":{"code":"START_FAILED"}})) if fail_start && path.ends_with?("/start")
    JSON.parse(%({"id":"sbx_test","status":"running"}))
  end
end

KEY = "test-key-012345678901234567890123456789"

def request(runtime, method, path, body = nil, auth = "Bearer #{KEY}")
  io = IO::Memory.new
  headers = HTTP::Headers{"Authorization" => auth}
  req = HTTP::Request.new(method, path, headers, body)
  response = HTTP::Server::Response.new(io)
  Sandcube::Service.new(runtime, KEY).call(HTTP::Server::Context.new(req, response))
  response.close
  HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
end

describe Sandcube::Service do
  it "rejects unauthenticated requests before touching the runtime" do
    runtime = FakeRuntime.new
    request(runtime, "POST", "/v1/sandboxes", "{}", "").status_code.should eq(401)
    runtime.calls.should be_empty
  end
  it "creates and starts a sandbox with defaults and a generated ID" do
    runtime = FakeRuntime.new
    result = request(runtime, "POST", "/v1/sandboxes", %({"image":"busybox","command":["sleep","infinity"]}))
    result.status_code.should eq(201)
    config = JSON.parse(runtime.calls[0][2].not_nil!)
    config["id"].as_s.should match(/^sbx_[a-f0-9]{32}$/)
    config["cpu"].as_i.should eq(1)
    runtime.calls[1][1].should eq("/containers/#{config["id"].as_s}/start")
  end
  it "rolls back the container if starting it fails" do
    runtime = FakeRuntime.new
    runtime.fail_start = true
    request(runtime, "POST", "/v1/sandboxes", %({"image":"busybox","command":["missing"]})).status_code.should eq(500)
    runtime.calls.map(&.[0]).should eq(["POST", "POST", "DELETE"])
  end
  it "rejects malformed, oversized and unsupported create input" do
    ["{", "null", "{}", "x" * 65537, %({"image":"x","command":[],"privileged":true})].each do |body|
      runtime = FakeRuntime.new
      request(runtime, "POST", "/v1/sandboxes", body).status_code.should eq(400)
      runtime.calls.should be_empty
    end
  end
  it "forwards lifecycle routes and exec arguments" do
    runtime = FakeRuntime.new
    request(runtime, "POST", "/v1/sandboxes/sbx_test/stop").status_code.should eq(200)
    request(runtime, "POST", "/v1/sandboxes/sbx_test/start").status_code.should eq(200)
    body = %({"command":["/bin/echo","hello"],"timeout_seconds":10})
    request(runtime, "POST", "/v1/sandboxes/sbx_test/exec", body).status_code.should eq(200)
    runtime.calls.last.should eq({"POST", "/containers/sbx_test/exec", body})
    request(runtime, "DELETE", "/v1/sandboxes/sbx_test").status_code.should eq(200)
  end
  it "rejects invalid routes and IDs" do
    runtime = FakeRuntime.new
    request(runtime, "POST", "/v1/sandboxes/host/delete").status_code.should eq(404)
    runtime.calls.should be_empty
  end
end

class FileRuntime < FakeRuntime
  def request(method : String, path : String, body : String? = nil) : JSON::Any
    super
    JSON.parse({content: Base64.strict_encode(Bytes[0, 255, 128, 10])}.to_json)
  end
end

describe "File and process API" do
  it "preserves binary upload and download bodies" do
    runtime = FileRuntime.new
    bytes = String.new(Bytes[0, 255, 128, 10])
    result = request(runtime, "PUT", "/v1/sandboxes/sbx_test/files/content?path=%2Fapp%2Fdata", bytes)
    result.status_code.should eq(200)
    input = JSON.parse(runtime.calls.last[2].not_nil!)
    input["path"].as_s.should eq("/app/data")
    Base64.decode(input["content"].as_s).should eq(bytes.to_slice)
    result = request(runtime, "GET", "/v1/sandboxes/sbx_test/files/content?path=/app/data")
    result.body.to_slice.should eq(bytes.to_slice)
    result.headers["Content-Type"].should eq("application/octet-stream")
  end

  it "rejects encoded traversal and oversized uploads before calling runtime" do
    runtime = FakeRuntime.new
    request(runtime, "GET", "/v1/sandboxes/sbx_test/files/content?path=%2F..%2Fhost").status_code.should eq(400)
    request(runtime, "PUT", "/v1/sandboxes/sbx_test/files/content?path=/large", "x" * (Sandcube::Files::MAX_TRANSFER + 1)).status_code.should eq(413)
    runtime.calls.should be_empty
  end

  it "forwards process creation, listing, status, logs and kill" do
    runtime = FakeRuntime.new
    prefix = "/v1/sandboxes/sbx_test/processes"
    body = %({"command":["sleep","100"]})
    request(runtime, "POST", prefix, body).status_code.should eq(202)
    runtime.calls.last.should eq({"POST", "/containers/sbx_test/processes", body})
    pid = "proc_" + "a" * 32
    {prefix, "#{prefix}/#{pid}", "#{prefix}/#{pid}/logs"}.each do |path|
      request(runtime, "GET", path).status_code.should eq(200)
    end
    request(runtime, "POST", "#{prefix}/#{pid}/kill").status_code.should eq(200)
    request(runtime, "GET", "#{prefix}/../../host").status_code.should eq(404)
  end
end
