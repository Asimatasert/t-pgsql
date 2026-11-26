# typed: false
# frozen_string_literal: true

class TPgsql < Formula
  desc "PostgreSQL database sync, backup and clone tool with notifications"
  homepage "https://github.com/Asimatasert/t-pgsql"
  url "https://github.com/Asimatasert/t-pgsql/archive/refs/tags/v3.12.1.tar.gz"
  sha256 "8fbd3424f8f6ddb00c1341c4b3aaa014c2994c462a38266eb85361d0688a5b0e"
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
    assert_match "v3.12.1", shell_output("#{bin}/t-pgsql --version")
  end
end
