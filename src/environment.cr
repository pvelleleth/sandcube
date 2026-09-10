require "dotenv"

module Sandcube::Environment
  # Deployment-provided values take precedence over the local file.
  def self.load(path : String = ".env") : Nil
    Dotenv.load?(path, override_keys: false)
  end
end
