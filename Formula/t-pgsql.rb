# typed: false
# frozen_string_literal: true

class TPgsql < Formula
  desc "PostgreSQL database sync, backup and clone tool with notifications"
  homepage "https://github.com/Asimatasert/t-pgsql"
  url "https://github.com/Asimatasert/t-pgsql/archive/refs/tags/v3.9.0.tar.gz"
  sha256 "78c4ac15a8f0da06d484a41e48a7bf696a765a3dd01572cf08501c24a8498905"
  license "MIT"
  head "https://github.com/Asimatasert/t-pgsql.git", branch: "master"

  depends_on "postgresql"
  depends_on "curl"

  def install
    bin.install "t-pgsql"
    zsh_completion.install "completions/_t-pgsql"
    bash_completion.install "completions/t-pgsql.bash" => "t-pgsql"
    fish_completion.install "completions/t-pgsql.fish"
    man1.install "man/t-pgsql.1"
  end

  test do
    assert_match "v3.9.0", shell_output("#{bin}/t-pgsql --version")
  end
end
