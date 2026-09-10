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
