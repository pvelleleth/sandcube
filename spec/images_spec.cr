require "spec"
require "../src/service"

class TestImageBuilder < Sandcube::ImageBuilder
  getter calls = [] of Tuple(String, String, Hash(String, String))
  getter deletes = [] of String
  property failure = false
  property delete_failure = false
  property gate : Channel(Nil)?

  def build(directory : String, reference : String, args : Hash(String, String)) : JSON::Any
    @calls << {directory, reference, args}
    @gate.try(&.receive)
    raise IO::Error.new("intentional build failure") if @failure
    JSON.parse({oci_digest: "sha256:" + "a" * 64}.to_json)
  end

  def delete(reference : String) : Nil
    @deletes << reference
    raise IO::Error.new("delete unavailable") if delete_failure
  end
end

class ImageTestRuntime < Sandcube::Runtime
  getter calls = [] of Tuple(String, String, String?)
  property fail_start = false
  property fail_delete = false

  def request(method : String, path : String, body : String? = nil) : JSON::Any
    @calls << {method, path, body}
    raise IO::Error.new("start failed") if fail_start && path.ends_with?("/start")
    raise IO::Error.new("delete failed") if fail_delete && method == "DELETE"
    JSON.parse(%({"status":"running"}))
  end
end

def image_request(service, method, path, body = nil, content_type = "application/json")
  io = IO::Memory.new
  req = HTTP::Request.new(method, path, HTTP::Headers{"Content-Type" => content_type}, body)
  response = HTTP::Server::Response.new(io)
  service.call(HTTP::Server::Context.new(req, response))
  response.close
  HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
end

def await_image(store, id, status)
  200.times do
    return if store.get(id)["status"].as_s == status
    sleep 0.01.seconds
  end
  fail "Image did not reach #{status}: #{store.get(id)}"
end

# Every example gets a fresh on-disk database, including recovery tests.
def with_image_test_database(&block : DB::Database ->)
  path = File.tempname("sandcube-spec-", ".db")
  db = Sandcube::Database.open(path)
  begin
    yield db
  ensure
    db.close
    File.delete(path)
  end
end

describe "SQLite image lifecycle" do
  it "serializes concurrent creation reservations against deletion" do
    with_image_test_database do |db|
      store = Sandcube::ImageStore.new(db)
      12.times do
        id = "img_#{UUID.random.to_s.gsub("-", "")}"
        sandbox = "sbx_#{UUID.random.to_s.gsub("-", "")}"
        begin
          store.create(id, nil, "FROM scratch")
          store.ready(id, "sha256:test")
          results = Channel(String).new
          spawn do
            begin
              store.reserve(id, sandbox)
              results.send("reserved")
            rescue ex : Sandcube::ImageError
              results.send(ex.code)
            end
          end
          spawn do
            begin
              store.begin_delete(id)
              results.send("deleting")
            rescue ex : Sandcube::ImageError
              results.send(ex.code)
            end
          end
          outcomes = [results.receive, results.receive].sort
          [{"IMAGE_IN_USE", "reserved"}.to_a.sort, {"IMAGE_NOT_READY", "deleting"}.to_a.sort].should contain(outcomes)
        ensure
          db.exec("DELETE FROM sandbox_images WHERE image_id=?1", id)
          db.exec("DELETE FROM images WHERE id=?1", id)
        end
      end
    end
  end

  it "marks interrupted builds ERROR and removes their abandoned directories on restart" do
    with_image_test_database do |db|
      store = Sandcube::ImageStore.new(db)
      id = "img_#{UUID.random.to_s.gsub("-", "")}"
      root = File.join(Dir.tempdir, "sandcube-images-spec-#{UUID.random}")
      begin
        store.create(id, nil, "FROM scratch")
        Dir.mkdir_p("#{root}/build-#{id}/context")
        File.write("#{root}/build-#{id}/image.tar", "partial")
        Sandcube::ImageManager.new(store, TestImageBuilder.new, root)
        store.get(id)["status"].as_s.should eq("ERROR")
        store.get(id)["error_message"].as_s.should contain("interrupted")
        Dir.glob("#{root}/build-*").should be_empty
      ensure
        db.exec("DELETE FROM images WHERE id=?1", id)
        FileUtils.rm_rf(root)
      end
    end
  end

  it "builds once, reserves two sandboxes, persists identity, and protects referenced images" do
    with_image_test_database do |db|
      store = Sandcube::ImageStore.new(db)
      builder = TestImageBuilder.new
      builder.gate = Channel(Nil).new
      runtime = ImageTestRuntime.new
      root = File.join(Dir.tempdir, "sandcube-images-spec-#{UUID.random}")
      ids = [] of String
      begin
        manager = Sandcube::ImageManager.new(store, builder, root)
        service = Sandcube::Service.new(runtime, manager, store)
        response = image_request(service, "POST", "/v1/images", {dockerfile: "FROM scratch", build_args: {VALUE: "a space; $(literal)"}}.to_json)
        response.status_code.should eq(202)
        id = JSON.parse(response.body)["id"].as_s
        ids << id
        store.get(id)["status"].as_s.should eq("BUILDING")
        image_request(service, "POST", "/v1/sandboxes", {image_id: id, command: ["sleep", "infinity"]}.to_json).status_code.should eq(409)
        image_request(service, "DELETE", "/v1/images/#{id}").status_code.should eq(409)
        builder.gate.not_nil!.send(nil)
        await_image(store, id, "READY")
        builder.calls.size.should eq(1)
        builder.calls[0][2]["VALUE"].should eq("a space; $(literal)")
        Dir.glob("#{root}/build-*").should be_empty
        sandboxes = [] of String
        2.times do
          response = image_request(service, "POST", "/v1/sandboxes", {image_id: id, command: ["sleep", "infinity"]}.to_json)
          response.status_code.should eq(201)
          JSON.parse(response.body)["image_id"].as_s.should eq(id)
          cfg = JSON.parse(runtime.calls[-2][2].not_nil!)
          cfg["image"].as_s.should eq(store.reference(id))
          sandboxes << cfg["id"].as_s
        end
        builder.calls.size.should eq(1)
        Sandcube::ImageStore.new(db).image_id(sandboxes[0]).should eq(id)
        image_request(service, "DELETE", "/v1/images/#{id}").status_code.should eq(409)
        image_request(service, "DELETE", "/v1/sandboxes/#{sandboxes[0]}").status_code.should eq(200)
        image_request(service, "DELETE", "/v1/images/#{id}").status_code.should eq(409)
        image_request(service, "DELETE", "/v1/sandboxes/#{sandboxes[1]}").status_code.should eq(200)
        builder.delete_failure = true
        image_request(service, "DELETE", "/v1/images/#{id}").status_code.should eq(503)
        store.get(id)["status"].as_s.should eq("DELETING")
        expect_raises(Sandcube::ImageError) { store.reserve(id, "sbx_blocked") }
        builder.delete_failure = false
        2.times { image_request(service, "DELETE", "/v1/images/#{id}").status_code.should eq(200) }
        builder.deletes.size.should eq(2)
        store.get(id)["status"].as_s.should eq("DELETED")
        image_request(service, "POST", "/v1/sandboxes", {image_id: id, command: ["sleep"]}.to_json).status_code.should eq(409)
      ensure
        ids.each do |id|
          db.exec("DELETE FROM sandbox_images WHERE image_id=?1", id)
          db.exec("DELETE FROM images WHERE id=?1", id)
        end
        FileUtils.rm_rf(root)
      end
    end
  end

  it "records failed builds, cleans temporary files and partial imports, and rejects unsafe uploads" do
    with_image_test_database do |db|
      store = Sandcube::ImageStore.new(db)
      builder = TestImageBuilder.new
      builder.failure = true
      root = File.join(Dir.tempdir, "sandcube-images-spec-#{UUID.random}")
      id : String? = nil
      begin
        manager = Sandcube::ImageManager.new(store, builder, root)
        service = Sandcube::Service.new(ImageTestRuntime.new, manager, store)
        response = image_request(service, "POST", "/v1/images", {dockerfile: "FROM scratch"}.to_json)
        id = JSON.parse(response.body)["id"].as_s
        await_image(store, id, "ERROR")
        store.get(id)["error_message"].as_s.should contain("intentional build failure")
        Dir.glob("#{root}/build-*").should be_empty
        builder.deletes.should eq([store.reference(id)])
        ["../escape", "/tmp/escape"].each do |path|
          response = image_request(service, "POST", "/v1/images", {dockerfile: "FROM scratch", context_tar_gz: Base64.strict_encode(gzip_tar(archive_entry(path)))}.to_json)
          response.status_code.should eq(400)
          Dir.glob("#{root}/build-*").should be_empty
        end
        [
          {dockerfile: "FROM scratch", context_tar_gz: "!invalid!"}.to_json,
          {dockerfile: "FROM scratch", build_args: {"BAD=KEY" => "value"}}.to_json,
          {dockerfile: "FROM scratch", build_args: {"COUNT" => 5}}.to_json,
          {dockerfile: ""}.to_json,
          {dockerfile: "FROM scratch", unexpected: true}.to_json,
        ].each do |invalid|
          image_request(service, "POST", "/v1/images", invalid).status_code.should eq(400)
        end
        image_request(service, "POST", "/v1/images", "broken", "multipart/form-data").status_code.should eq(400)
        Dir.glob("#{root}/build-*").should be_empty
        builder.calls.size.should eq(1)
        image_request(service, "DELETE", "/v1/images/#{id}").status_code.should eq(200)
      ensure
        db.exec("DELETE FROM images WHERE id=?1", id) if id
        FileUtils.rm_rf(root)
      end
    end
  end

  it "retains reservations when rollback fails and releases them after successful deletion" do
    with_image_test_database do |db|
      store = Sandcube::ImageStore.new(db)
      id = "img_#{UUID.random.to_s.gsub("-", "")}"
      begin
        store.create(id, nil, "FROM scratch")
        store.ready(id, "sha256:test")
        runtime = ImageTestRuntime.new
        runtime.fail_start = true
        runtime.fail_delete = true
        service = Sandcube::Service.new(runtime, nil, store)
        image_request(service, "POST", "/v1/sandboxes", {image_id: id, command: ["sleep"]}.to_json).status_code.should eq(503)
        sandbox = JSON.parse(runtime.calls[0][2].not_nil!)["id"].as_s
        expect_raises(Sandcube::ImageError, "referenced") { store.begin_delete(id) }
        runtime.fail_delete = false
        image_request(service, "DELETE", "/v1/sandboxes/#{sandbox}").status_code.should eq(200)
        store.begin_delete(id)["status"].as_s.should eq("DELETING")
      ensure
        db.exec("DELETE FROM sandbox_images WHERE image_id=?1", id)
        db.exec("DELETE FROM images WHERE id=?1", id)
      end
    end
  end
end
