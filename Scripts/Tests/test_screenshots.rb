require "minitest/autorun"
require "tmpdir"
require_relative "../../fastlane/lib/screenshots"

class ScreenshotsTests < Minitest::Test
  def setup
    @root = Dir.mktmpdir("termind-screenshots-")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def runner(platform = :ios, options = {}, environment = {})
    Screenshots.new(platform, options, environment: environment, root: @root)
  end

  def test_lane_options_override_legacy_selectors_and_ipad_only_needs_no_iphone
    capture = runner(:ios, { devices: "ipad", locales: "zh-Hant", scenes: "ssh,sftp" },
                     { "TERMIND_SCREENSHOT_DEVICES" => "iphone", "TERMIND_SCREENSHOT_LOCALES" => "en" })
    capture.define_singleton_method(:command) do |*args|
      JSON.generate("devices" => { "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [
        { "name" => "iPad Pro 13-inch (M5)", "udid" => "ipad-id",
          "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB" }
      ] })
    end
    assert_equal ["ipad"], capture.find_devices.keys
    assert_equal 2, capture.plan[:captures]
    assert_equal ["zh-Hant"], capture.plan[:locales]
  end

  def test_a_renamed_pro_max_cannot_be_used_as_the_pro_capture_device
    capture = runner(:ios, devices: "iphone")
    capture.define_singleton_method(:command) do |*args|
      JSON.generate("devices" => { "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [
        { "name" => "iPhone 17 Pro", "udid" => "wrong-model",
          "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max" }
      ] })
    end
    assert_raises(RuntimeError) { capture.find_devices }
    capture.define_singleton_method(:dimensions) { |_| [1320, 2868] }
    assert_raises(RuntimeError) do
      capture.validate_dimensions("pro-max.png", Screenshots::DEVICES.fetch("iphone").fetch(:dimensions))
    end
  end

  def test_rejects_invalid_duplicate_and_empty_members_before_build
    ["ssh,ssh", "ssh,", "bogus"].each do |scenes|
      assert_raises(ArgumentError) { runner(:ios, scenes: scenes) }
    end
    assert_raises(ArgumentError) { runner(:mac, scenes: "metrics-detail") }
    assert_raises(ArgumentError) { runner(:ios, locales: "zh") }
    assert_raises(ArgumentError) { runner(:ios, devices: "watch") }
    assert_raises(ArgumentError) { runner(:ios, runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-0") }
  end

  def test_generated_xctestrun_preserves_host_settings_and_other_targets
    capture = runner
    fixture = { "EnvironmentVariables" => { "EXISTING" => "preserved" }, "TestHostPath" => "__TESTROOT__/App.app" }
    document = { "TFITests" => fixture, "FrameworkTests" => { "CommandLineArguments" => ["unchanged"] } }
    capture.configure_xctestrun(document, "zh-Hans", { "TERMIND_SCREENSHOTS" => "1" }, [])
    assert_equal "preserved", fixture["EnvironmentVariables"]["EXISTING"]
    assert_equal "__TESTROOT__/App.app", fixture["TestHostPath"]
    assert_equal "CN", fixture["TestRegion"]
    assert_equal ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"], fixture["CommandLineArguments"]
    assert_equal ["unchanged"], document["FrameworkTests"]["CommandLineArguments"]
  end

  def test_test_plan_format_updates_only_the_capture_target
    capture = runner(:mac)
    target = { "BlueprintName" => "TFMTests" }
    other = { "BlueprintName" => "FrameworkTests" }
    document = { "TestConfigurations" => [{ "TestTargets" => [target, other] }] }
    capture.configure_xctestrun(document, "zh-Hant", {}, ["--termind-demo=hosts:zh-Hant"])
    assert_equal "TW", target["TestRegion"]
    assert_equal "--termind-demo=hosts:zh-Hant", target["CommandLineArguments"].first
    refute other.key?("TestLanguage")
  end

  def test_scan_configuration_pins_dependencies_and_serializes_hosted_tests
    options = runner.scan_options("id=ipad", "vault-en")
    assert_includes options[:xcargs], "-onlyUsePackageVersionsFromResolvedFile"
    assert options[:skip_package_dependencies_resolution]
    assert options[:disable_package_automatic_updates]
    refute options[:parallel_testing]
    assert options[:disable_concurrent_testing]
    assert_equal 0, options[:number_of_retries]
  end

  def test_successful_capture_backs_up_original_bytes_and_manifest
    capture = runner
    original = File.join(@root, "Marketing/Screenshots/Captures/vault/ipad-en.png")
    FileUtils.mkdir_p(File.dirname(original))
    File.binwrite(original, "old image bytes")
    source = File.join(@root, "new.png")
    File.binwrite(source, "new image bytes")
    capture.promote([[source, "vault/ipad-en.png"]])
    assert_equal "new image bytes", File.binread(original)
    backup = Dir.glob(File.join(@root, ".build/screenshot-backups/*/vault/ipad-en.png")).fetch(0)
    assert_equal "old image bytes", File.binread(backup)
    manifest = File.read(File.join(File.dirname(File.dirname(backup)), "SHA256SUMS"))
    assert_equal "#{Digest::SHA256.hexdigest('old image bytes')}  vault/ipad-en.png\n", manifest
  end

  def test_failed_scan_never_promotes_a_staged_mac_capture
    capture = runner(:mac, scenes: "hosts", locales: "en")
    capture.define_singleton_method(:test_configuration) { |*| File.join(@root, "test.xctestrun") }
    capture.instance_variable_set(:@scan, ->(_) { raise "scan failed" })
    error = assert_raises(RuntimeError) { capture.capture_mac("hosts", "en", "platform=macOS") }
    assert_equal "scan failed", error.message
    refute Dir.exist?(File.join(@root, "Marketing/Screenshots/Captures"))
  end

  def test_capture_failure_is_reported_even_if_scan_succeeds
    capture = runner
    attempted = Queue.new
    capture.instance_variable_set(:@scan, ->(_) { attempted.pop })
    error = assert_raises(RuntimeError) do
      capture.capture_during_test({}) do
        attempted << true
        raise "native capture failed"
      end
    end
    assert_equal "native capture failed", error.message
  end
end

require "minitest/mock"
require "fastlane"
require "frameit"
require "zlib"
require_relative "../../fastlane/lib/screenshot_frames"

class ScreenshotFramesTests < Minitest::Test
  def setup
    @root = Dir.mktmpdir("termind-frames-")
    FileUtils.mkdir_p(File.join(@root, "fastlane"))
    FileUtils.cp(File.expand_path("../../fastlane/Framefile.json", __dir__), File.join(@root, "fastlane"))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def png(path, width, height)
    chunk = lambda do |name, bytes|
      [bytes.bytesize].pack("N") + name + bytes + [Zlib.crc32(name + bytes)].pack("N")
    end
    data = "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC"))
    data += chunk.call("IDAT", Zlib.deflate(("\0" * (width * 3 + 1)) * height)) + chunk.call("IEND", "")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, data)
  end

  def test_rejects_old_pro_max_sources_before_calling_frameit
    source = File.join(@root, "Marketing/Screenshots/Captures/vault/iphone-en.png")
    png(source, 1320, 2868)
    runner = ScreenshotFrames.new({ devices: "iphone", scenes: "vault", locales: "en" }, root: @root)
    called = false
    assert_raises(RuntimeError) { runner.run { called = true } }
    refute called
    refute Dir.exist?(File.join(@root, "Marketing/Screenshots/DeviceFrames"))
  end

  def test_missing_frameit_output_keeps_all_existing_outputs_and_sources
    %w[en zh-hans].each do |locale|
      png(File.join(@root, "Marketing/Screenshots/Captures/vault/iphone-#{locale}.png"), 1206, 2622)
    end
    destination = File.join(@root, "Marketing/Screenshots/DeviceFrames/vault/iphone-en-framed.png")
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, "existing frame")
    source = File.join(@root, "Marketing/Screenshots/Captures/vault/iphone-en.png")
    original_hash = Digest::SHA256.file(source).hexdigest
    runner = ScreenshotFrames.new({ devices: "iphone", scenes: "vault", locales: "en,zh-Hans" }, root: @root)
    downloader = Object.new
    downloader.define_singleton_method(:frames_exist?) { true }
    calls = 0
    Frameit::FrameDownloader.stub(:new, downloader) do
      assert_raises(RuntimeError) do
        runner.run do |options|
          calls += 1
          png(File.join(options.fetch(:path), "iphone_framed.png"), 1350, 2760) if calls == 1
          # frameit can log an error and return successfully without an image.
        end
      end
    end
    assert_equal 2, calls
    assert_equal "existing frame", File.read(destination)
    assert_equal original_hash, Digest::SHA256.file(source).hexdigest
    refute File.exist?(destination.sub("-en-", "-zh-hans-"))
  end
end
