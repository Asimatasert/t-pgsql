# typed: false
# frozen_string_literal: true

class TPgsql < Formula
  desc "PostgreSQL database sync, backup and clone tool with notifications"
  homepage "https://github.com/Asimatasert/t-pgsql"
  url "https://github.com/Asimatasert/t-pgsql/archive/refs/tags/v3.14.0.tar.gz"
  sha256 "347a80416756e345910276b348312e4840084fd3303a0d257db1633a23f8bf5e"
  license "MIT"
  head "https://github.com/Asimatasert/t-pgsql.git", branch: "master"

  depends_on "postgresql"
  depends_on "curl"

  # Optional tools the script calls only for the matching feature: zstd, xz,
  # bzip2 (compressed dumps), pv (progress), python3 (bot JSON parsing) and
  # ssh/scp (remote hosts; ships with macOS). Homebrew cannot express
  # "recommended" dependencies in a core-style formula, so install them
  # yourself: brew install zstd xz pv

  def install
    bin.install "t-pgsql"
    zsh_completion.install "completions/_t-pgsql"
    bash_completion.install "completions/t-pgsql.bash" => "t-pgsql"
    fish_completion.install "completions/t-pgsql.fish"
    man1.install "man/t-pgsql.1"
  end

  test do
    assert_match "v3.14.0", shell_output("#{bin}/t-pgsql --version")
  end
end
