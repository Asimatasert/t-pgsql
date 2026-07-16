# typed: false
# frozen_string_literal: true

class TPgsql < Formula
  desc "PostgreSQL database sync, backup and clone tool with notifications"
  homepage "https://github.com/Asimatasert/t-pgsql"
  url "https://github.com/Asimatasert/t-pgsql/archive/refs/tags/v3.11.0.tar.gz"
  sha256 "dc02b5219cf71cb811cb830329877a0a33c8143069c42cd729be8904d5ef1fec"
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
    assert_match "v3.11.0", shell_output("#{bin}/t-pgsql --version")
  end
end
