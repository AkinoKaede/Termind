require "minitest/autorun"
require "tmpdir"
require_relative "../../fastlane/lib/screenshots"

class ScreenshotsTests < Minitest::Test
  def setup
    @root = Dir.mktmpdir("termind-screenshots-")
    FileUtils.mkdir_p(File.join(@root, "com.akinokaede.termind/assets"))
    File.write(File.join(@root, "com.akinokaede.termind/.git"), "gitdir: fixture")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def runner(platform = :ios, options = {}, environment = {})
    Screenshots.new(platform, options, environment: environment, root: @root)
  end

  def test_default_capture_fails_before_build_when_submodule_is_missing
    FileUtils.remove_entry(File.join(@root, "com.akinokaede.termind"))
    error = assert_raises(RuntimeError) { runner.run { flunk "scan must not start" } }
    assert_includes error.message, "git submodule update --init com.akinokaede.termind"
    refute Dir.exist?(File.join(@root, ".build"))
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind"))
  end

  def test_explicit_capture_output_can_publish_without_submodule
    FileUtils.remove_entry(File.join(@root, "com.akinokaede.termind"))
    source = File.join(@root, "capture.png")
    File.binwrite(source, "review capture")
    capture = runner(:ios, output: "review")
    capture.promote([[source, "en/ipad/vault.png"]])
    assert_equal "review capture", File.binread(File.join(@root, "review/en/ipad/vault.png"))
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind"))
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

  def test_a_renamed_pro_cannot_be_used_as_the_pro_max_capture_device
    capture = runner(:ios, devices: "iphone")
    capture.define_singleton_method(:command) do |*args|
      JSON.generate("devices" => { "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [
        { "name" => "iPhone 17 Pro Max", "udid" => "wrong-model",
          "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" }
      ] })
    end
    assert_raises(RuntimeError) { capture.find_devices }
    capture.define_singleton_method(:dimensions) { |_| [1206, 2622] }
    assert_raises(RuntimeError) do
      capture.validate_dimensions("pro.png", Screenshots::DEVICES.fetch("iphone").fetch(:dimensions))
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
    original = File.join(@root, "com.akinokaede.termind/assets/captures/en/ipad/vault.png")
    FileUtils.mkdir_p(File.dirname(original))
    File.binwrite(original, "old image bytes")
    source = File.join(@root, "new.png")
    File.binwrite(source, "new image bytes")
    capture.promote([[source, "en/ipad/vault.png"]])
    assert_equal "new image bytes", File.binread(original)
    backup = Dir.glob(File.join(@root, ".build/screenshot-backups/*/en/ipad/vault.png")).fetch(0)
    assert_equal "old image bytes", File.binread(backup)
    manifest = File.read(File.join(File.dirname(File.dirname(File.dirname(backup))), "SHA256SUMS"))
    assert_equal "#{Digest::SHA256.hexdigest('old image bytes')}  en/ipad/vault.png\n", manifest
  end

  def test_mac_captures_publish_localized_underscore_filenames
    { "command" => "command_generator", "metrics" => "metrics_overview" }.each do |scene, filename|
      capture = runner(:mac, scenes: scene, locales: "zh-Hant")
      capture.define_singleton_method(:test_configuration) { |*| File.join(@root, "test.xctestrun") }
      capture.define_singleton_method(:capture_during_test) do |options, &block|
        log = File.join(options.fetch(:buildlog_path), "Termind-TFM.log")
        FileUtils.mkdir_p(File.dirname(log))
        File.write(log, "TERMIND_MAC_SCREENSHOT_READY #{scene}\tzh-Hant\t123\ttoken\tactive\tkey\t2360\t1480\n")
        block.call
      end
      capture.define_singleton_method(:command) do |*args|
        raise "Unexpected command" unless args.first == "screencapture"
        FileUtils.mkdir_p(File.dirname(args.last))
        File.binwrite(args.last, "captured #{scene}")
      end
      capture.define_singleton_method(:dimensions) { |_| [2360, 1480] }
      capture.capture_mac(scene, "zh-Hant", "platform=macOS")
      destination = File.join(@root, "com.akinokaede.termind/assets/captures/zh-hant/mac/#{filename}.png")
      assert_equal "captured #{scene}", File.binread(destination)
    end
  end

  def test_mac_camera_strip_is_padded_without_stretching_full_screen_capture
    capture = runner(:mac, scenes: "workspace", locales: "en")
    capture.define_singleton_method(:test_configuration) { |*| File.join(@root, "test.xctestrun") }
    capture.define_singleton_method(:capture_during_test) do |options, &block|
      log = File.join(options.fetch(:buildlog_path), "Termind-TFM.log")
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, "TERMIND_MAC_SCREENSHOT_READY workspace\ten\t123\ttoken\tactive\tkey\t3024\t1964\n")
      block.call
    end
    calls = []
    capture.define_singleton_method(:command) do |*args|
      calls << args
      if args.first == "screencapture"
        FileUtils.mkdir_p(File.dirname(args.last))
        File.binwrite(args.last, "full-screen window")
      end
    end
    sizes = [[3024, 1890], [3024, 1964]]
    capture.define_singleton_method(:dimensions) { |_| sizes.shift }
    capture.capture_mac("workspace", "en", "platform=macOS")
    padding = calls.find { |args| args.first == "magick" }
    assert_includes padding, "3024x1964"
    assert_includes padding, "south"
    refute_includes padding, "-resize"
    assert_equal ["screencapture", "-l", "123", "-o"], calls.first.first(4)
  end

  def test_mobile_capture_rediscovers_container_after_host_reinstallation
    capture = runner(:ios, devices: "iphone", scenes: "vault", locales: "zh-Hans")
    old_container = File.join(@root, "old-container")
    new_container = File.join(@root, "new-container")
    control = File.join(new_container, "Documents", "screenshot-capture-control")
    token = "11111111-1111-1111-1111-111111111111"
    capture.define_singleton_method(:test_configuration) do |_, _, environment|
      FileUtils.mkdir_p(control)
      File.write(File.join(control, "ready"), ["vault", "iphone", "zh-hans", token,
                 environment.fetch("TERMIND_SCREENSHOT_CAPTURE_ID")].join("\t"))
      File.join(@root, "fixture.xctestrun")
    end
    capture.define_singleton_method(:capture_during_test) { |_, &block| 2.times { block.call } }
    capture.define_singleton_method(:command) do |*args|
      if args.include?("screenshot")
        FileUtils.mkdir_p(File.dirname(args.last))
        File.binwrite(args.last, "new container capture")
      end
      ""
    end
    capture.define_singleton_method(:dimensions) { |_| [1320, 2868] }
    containers = [old_container, new_container]
    status = Object.new
    status.define_singleton_method(:success?) { true }
    responses = lambda do |*args|
      [args.include?("get_app_container") ? containers.shift : "", status]
    end
    Open3.stub(:capture2e, responses) do
      capture.capture_mobile("iphone", { "udid" => "fixture", "state" => "Booted" }, "zh-Hans")
    end
    destination = File.join(@root, "com.akinokaede.termind/assets/captures/zh-hans/iphone/vault.png")
    assert_equal "new container capture", File.binread(destination)
    assert File.exist?(File.join(control, "ack-#{token}"))
    refute Dir.exist?(old_container)
  end

  def test_failed_scan_never_promotes_a_staged_mac_capture
    capture = runner(:mac, scenes: "hosts", locales: "en")
    capture.define_singleton_method(:test_configuration) { |*| File.join(@root, "test.xctestrun") }
    capture.instance_variable_set(:@scan, ->(_) { raise "scan failed" })
    error = assert_raises(RuntimeError) { capture.capture_mac("hosts", "en", "platform=macOS") }
    assert_equal "scan failed", error.message
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind/assets/captures"))
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
    FileUtils.mkdir_p(File.join(@root, "com.akinokaede.termind/assets"))
    File.write(File.join(@root, "com.akinokaede.termind/.git"), "gitdir: fixture")
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

  def test_default_frames_only_include_website_used_scenes
    jobs = ScreenshotFrames.new({}, root: @root).plan
    assert_equal 21, jobs.size
    refute jobs.any? { |job| job[:input].end_with?("/ipad/ssh.png", "/iphone/metrics.png") }
    explicit = ScreenshotFrames.new({ devices: "ipad", scenes: "ssh", locales: "en" }, root: @root).plan
    assert_equal 1, explicit.size
    assert explicit.first[:input].end_with?("/ipad/ssh.png")
  end

  def test_default_frames_fail_before_creating_outputs_when_submodule_is_missing
    FileUtils.remove_entry(File.join(@root, "com.akinokaede.termind"))
    runner = ScreenshotFrames.new({ devices: "iphone", scenes: "vault", locales: "en" }, root: @root)
    error = assert_raises(RuntimeError) { runner.run { flunk "frameit must not start" } }
    assert_includes error.message, "git submodule update --init com.akinokaede.termind"
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind"))
  end

  def test_explicit_frame_paths_work_without_submodule_and_keep_source_bytes
    FileUtils.remove_entry(File.join(@root, "com.akinokaede.termind"))
    source = File.join(@root, "review-input/en/iphone/vault.png")
    png(source, 1320, 2868)
    original_hash = Digest::SHA256.file(source).hexdigest
    runner = ScreenshotFrames.new({ devices: "iphone", scenes: "vault", locales: "en",
                                    input: "review-input", output: "review-output" }, root: @root)
    downloader = Object.new
    downloader.define_singleton_method(:frames_exist?) { true }
    Frameit::FrameDownloader.stub(:new, downloader) do
      runner.run do |options|
        assert_equal "iPhone 17 Pro Max", options.fetch(:force_device_type)
        png(File.join(options.fetch(:path), "iphone_framed.png"), 1458, 3006)
      end
    end
    assert File.exist?(File.join(@root, "review-output/en/iphone/vault.png"))
    assert_equal original_hash, Digest::SHA256.file(source).hexdigest
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind"))
  end

  def test_rejects_pro_sources_before_calling_frameit
    source = File.join(@root, "com.akinokaede.termind/assets/captures/en/iphone/vault.png")
    png(source, 1206, 2622)
    runner = ScreenshotFrames.new({ devices: "iphone", scenes: "vault", locales: "en" }, root: @root)
    called = false
    assert_raises(RuntimeError) { runner.run { called = true } }
    refute called
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind/assets/device_frames"))
  end

  def test_missing_frameit_output_keeps_all_existing_outputs_and_sources
    %w[en zh-hans].each do |locale|
      png(File.join(@root, "com.akinokaede.termind/assets/captures/#{locale}/iphone/vault.png"), 1320, 2868)
    end
    destination = File.join(@root, "com.akinokaede.termind/assets/device_frames/en/iphone/vault.png")
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, "existing frame")
    source = File.join(@root, "com.akinokaede.termind/assets/captures/en/iphone/vault.png")
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
    refute File.exist?(destination.sub("/en/", "/zh-hans/"))
  end
end
