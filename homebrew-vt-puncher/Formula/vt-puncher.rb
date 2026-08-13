class VtReborn < Formula
  desc "vt-reborn - Native macOS replacement for the VisualTime portal"
  homepage "https://github.com/ivanhirskyy/vt-reborn"
  version "1.0.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/ivanhirskyy/vt-reborn/releases/download/v#{version}/vt-reborn.zip"
      sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
    else
      url "https://github.com/ivanhirskyy/vt-reborn/releases/download/v#{version}/vt-reborn.zip"
      sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
    end
  end

  def install
    prefix.install "vt-reborn.app"
    bin.write_exec_script prefix/"vt-reborn.app/Contents/MacOS/vt-reborn"
  end

  def caveats
    <<~EOS
      vt-reborn.app installed to #{opt_prefix}
      Run with: vt-reborn
      Or open from Applications/Spotlight.
    EOS
  end

  test do
    assert_predicate prefix/"vt-reborn.app", :exist?
  end
end