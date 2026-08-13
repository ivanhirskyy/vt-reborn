class VtPuncher < Formula
  desc "VT Puncher - Native macOS replacement for the VisualTime portal"
  homepage "https://github.com/ivanhirskyy/vt-reborn"
  version "1.0.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/ivanhirskyy/vt-reborn/releases/download/v#{version}/VTPuncher.zip"
      sha256 "REPLACE_WITH_ACTUAL_SHA256_AFTER_FIRST_RELEASE"
    else
      url "https://github.com/ivanhirskyy/vt-reborn/releases/download/v#{version}/VTPuncher.zip"
      sha256 "REPLACE_WITH_ACTUAL_SHA256_AFTER_FIRST_RELEASE"
    end
  end

  def install
    prefix.install "VTPuncher.app"
    bin.write_exec_script prefix/"VTPuncher.app/Contents/MacOS/VTPuncher"
  end

  def caveats
    <<~EOS
      VTPuncher.app installed to #{opt_prefix}
      Run with: vt-puncher
      Or open from Applications/Spotlight.
    EOS
  end

  test do
    assert_predicate prefix/"VTPuncher.app", :exist?
  end
end