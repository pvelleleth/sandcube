require "spec"
require "../src/environment"

describe Sandcube::Environment do
  it "loads quoted connection strings and preserves deployment overrides" do
    file = File.tempfile("sandcube-env")
    file.close
    keys = %w(SANDCUBE_TEST_ENV_URL SANDCUBE_TEST_ENV_OVERRIDE SANDCUBE_TEST_ENV_EMPTY)
    original = keys.to_h { |key| {key, ENV[key]?} }
    begin
      ENV.delete(keys[0])
      ENV[keys[1]] = "deployment"
      ENV[keys[2]] = ""
      File.write(file.path, <<-ENVFILE)
        # A connection string must retain punctuation and query parameters.
        SANDCUBE_TEST_ENV_URL='postgres://user:password@example.invalid/db?sslmode=require&connect_timeout=10'
        SANDCUBE_TEST_ENV_OVERRIDE=file
        SANDCUBE_TEST_ENV_EMPTY=file
        ENVFILE
      Sandcube::Environment.load(file.path)
      ENV[keys[0]].should eq("postgres://user:password@example.invalid/db?sslmode=require&connect_timeout=10")
      ENV[keys[1]].should eq("deployment")
      ENV[keys[2]].should eq("")
    ensure
      original.each { |key, value| ENV[key] = value }
      File.delete(file.path)
    end
  end

  it "allows startup without a local environment file" do
    file = File.tempfile("sandcube-env-missing")
    file.close
    File.delete(file.path)
    Sandcube::Environment.load(file.path).should be_nil
  end
end
