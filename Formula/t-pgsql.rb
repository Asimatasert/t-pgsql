# typed: false
# frozen_string_literal: true

class TPgsql < Formula
  desc "Advanced CLI tool for backing up, restoring, and synchronizing PostgreSQL databases"
  homepage "https://github.com/Asimatasert/t-pgsql"
  url "https://github.com/Asimatasert/t-pgsql/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"
  license "MIT"
  head "https://github.com/Asimatasert/t-pgsql.git", branch: "master"

  depends_on "postgresql"

  def install
    bin.install "t-pgsql"
  end

  test do
    assert_match "t-pgsql", shell_output("#{bin}/t-pgsql --version")
  end
end
