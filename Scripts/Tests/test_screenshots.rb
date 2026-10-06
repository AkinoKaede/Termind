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
    capture.promote([[source, "en/ipad-15/vault.png"]])
    assert_equal "review capture", File.binread(File.join(@root, "review/en/ipad-15/vault.png"))
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

  def test_runtime_defaults_follow_device_compatibility_and_allow_explicit_overrides
    assert_equal "com.apple.CoreSimulator.SimRuntime.iOS-27-0", runner.plan[:runtime]
    assert_equal "com.apple.CoreSimulator.SimRuntime.iOS-27-1", runner(:ios, devices: "iphone-duo-inner").plan[:runtime]
    assert_equal "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                 runner(:ios, { devices: "iphone-duo-inner", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0" }).plan[:runtime]
  end

  def test_a_renamed_pro_max_cannot_be_used_as_the_pro_capture_device
    capture = runner(:ios, devices: "iphone")
    capture.define_singleton_method(:command) do |*args|
      JSON.generate("devices" => { "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [
        { "name" => "iPhone 18 Pro", "udid" => "wrong-model",
          "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max" }
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
    original = File.join(@root, "com.akinokaede.termind/assets/captures/en/ipad-15/vault.png")
    FileUtils.mkdir_p(File.dirname(original))
    File.binwrite(original, "old image bytes")
    source = File.join(@root, "new.png")
    File.binwrite(source, "new image bytes")
    capture.promote([[source, "en/ipad-15/vault.png"]])
    assert_equal "new image bytes", File.binread(original)
    backup = Dir.glob(File.join(@root, ".build/screenshot-backups/*/en/ipad-15/vault.png")).fetch(0)
    assert_equal "old image bytes", File.binread(backup)
    manifest = File.read(File.join(File.dirname(File.dirname(File.dirname(backup))), "SHA256SUMS"))
    assert_equal "#{Digest::SHA256.hexdigest('old image bytes')}  en/ipad-15/vault.png\n", manifest
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
      destination = File.join(@root, "com.akinokaede.termind/assets/captures/zh-hant/mac-14/#{filename}.png")
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
    %w[iphone ipad iphone-duo-outer iphone-duo-inner].each do |device|
      assert_mobile_capture_rediscovers_container(device)
    end
  end

  def assert_mobile_capture_rediscovers_container(device)
    capture = runner(:ios, devices: device, scenes: "vault", locales: "zh-Hans")
    old_container = File.join(@root, "old-container")
    new_container = File.join(@root, "new-container")
    control = File.join(new_container, "Documents", "screenshot-capture-control")
    token = "11111111-1111-1111-1111-111111111111"
    capture.define_singleton_method(:test_configuration) do |_, _, environment|
      FileUtils.mkdir_p(control)
      File.write(File.join(control, "ready"), ["vault", environment.fetch("TERMIND_SCREENSHOT_DEVICE"), "zh-hans", token,
                 environment.fetch("TERMIND_SCREENSHOT_CAPTURE_ID")].join("\t"))
      File.join(@root, "fixture.xctestrun")
    end
    capture.define_singleton_method(:capture_during_test) { |_, &block| 2.times { block.call } }
    commands = []
    capture.define_singleton_method(:sleep) { |_| }
    capture.define_singleton_method(:command) do |*args|
      commands << args
      if args.include?("displays")
        next JSON.generate("result" => { "displays" => [
          { "active" => true, "nativeSize" => Screenshots::DEVICES.fetch(device).fetch(:dimensions).sort,
            "uniqueId" => "display-#{device}" }
        ] })
      end
      if args.include?("screenshot")
        FileUtils.mkdir_p(File.dirname(args.last))
        File.binwrite(args.last, "new container capture")
      end
      ""
    end
    capture.define_singleton_method(:dimensions) { |_| Screenshots::DEVICES.fetch(device).fetch(:dimensions) }
    containers = [old_container, new_container]
    status = Object.new
    status.define_singleton_method(:success?) { true }
    responses = lambda do |*args|
      [args.include?("get_app_container") ? containers.shift : "", status]
    end
    Open3.stub(:capture2e, responses) do
      capture.capture_mobile(device, { "udid" => "fixture", "state" => "Booted" }, "zh-Hans")
    end
    folder = { "iphone" => "iphone-6.3", "ipad" => "ipad-15" }.fetch(device, device)
    destination = File.join(@root, "com.akinokaede.termind/assets/captures/zh-hans/#{folder}/vault.png")
    assert_equal "new container capture", File.binread(destination)
    assert File.exist?(File.join(control, "ack-#{token}"))
    refute Dir.exist?(old_container)
    status_bar = commands.find { |args| args.include?("override") }
    assert_equal "discharging", status_bar[status_bar.index("--batteryState") + 1]
    assert_equal "100", status_bar[status_bar.index("--batteryLevel") + 1]
    if device == "iphone-duo-outer"
      assert_includes commands.find { |args| args.include?("screenshot") }, "--display=primary"
    elsif device == "iphone-duo-inner"
      screenshot = commands.find { |args| args.include?("screenshot") }
      assert_includes screenshot, "--display-unique-id"
      assert_includes screenshot, "display-iphone-duo-inner"
    end
    FileUtils.remove_entry(new_container)
  end

  def test_duo_rejects_the_inactive_display_before_starting_capture
    capture = runner(:ios, devices: "iphone-duo-inner")
    capture.define_singleton_method(:command) do |*args|
      JSON.generate("result" => { "displays" => [
        { "active" => true, "nativeSize" => [1398, 2034] },
        { "active" => false, "nativeSize" => [2007, 2853] }
      ] })
    end
    error = assert_raises(RuntimeError) { capture.validate_display("iphone-duo-inner", "duo-id") }
    assert_includes error.message, "Select Open"
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
    frame_template(File.join(@root, ".build/frameit-assets/iphone-18-pro.png"), 1350, 2760)
    @templates = File.join(@root, "templates")
    FileUtils.mkdir_p(@templates)
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

  def frame_template(path, width, height)
    FileUtils.mkdir_p(File.dirname(path))
    ScreenshotFrames.new.command("magick", "-size", "#{width}x#{height}", "xc:none",
                                 "-fill", "none", "-stroke", "black", "-strokewidth", "40",
                                 "-draw", "roundrectangle 40,40,#{width - 41},#{height - 41},100,100", path)
  end

  def test_screen_mask_removes_exterior_corners_without_fading_content
    runner = ScreenshotFrames.new
    template = File.join(@root, "rounded-frame.png")
    runner.command("magick", "-size", "120x180", "xc:none", "-fill", "none", "-stroke", "black",
                   "-strokewidth", "8", "-draw", "roundrectangle 8,8,111,171,25,25",
                   "-fill", "black", "-stroke", "none", "-draw", "rectangle 50,8,70,28", template)
    [0, -90, 90].each do |rotation|
      landscape = !rotation.zero?
      source = File.join(@root, "screen.png")
      runner.command("magick", "-size", landscape ? "160x100" : "100x160", "xc:#327abe", source)
      runner.mask_screen(source, template, "+10+10", rotation: rotation)
      assert_equal(landscape ? [160, 100] : [100, 160], FastImage.size(source))
      center = landscape ? "80,50" : "50,80"
      assert_equal "1", runner.command("magick", source, "-format", "%[fx:p{#{center}}.a]", "info:").strip
      assert_equal "0", runner.command("magick", source, "-format", "%[fx:p{0,0}.a]", "info:").strip
      assert_equal "50,122,190", runner.command("magick", source, "-format",
                                               "%[fx:round(255*p{#{center}}.r)],%[fx:round(255*p{#{center}}.g)],%[fx:round(255*p{#{center}}.b)]", "info:").strip
      notch = { 0 => "50,5", -90 => "5,50", 90 => "155,50" }.fetch(rotation)
      assert_equal "0", runner.command("magick", source, "-format", "%[fx:p{#{notch}}.a]", "info:").strip
    end
  end

  def test_screen_mask_rejects_an_open_bezel
    runner = ScreenshotFrames.new
    template = File.join(@root, "open-frame.png")
    source = File.join(@root, "screen.png")
    runner.command("magick", "-size", "120x180", "xc:none", template)
    png(source, 100, 160)
    original = Digest::SHA256.file(source).hexdigest
    assert_raises(RuntimeError) { runner.mask_screen(source, template, "+10+10") }
    assert_equal original, Digest::SHA256.file(source).hexdigest
  end

  def test_mac_composition_clips_corners_and_preserves_source_and_content
    template = File.join(@root, "mac-frame.png")
    runner = ScreenshotFrames.new({ mac_frame: template }, root: @root)
    runner.command("magick", "-size", "3860x2320", "xc:none", "-fill", "none",
                   "-stroke", "black", "-strokewidth", "20",
                   "-draw", "roundrectangle 408,58,3451,2041,100,100", template)
    source = File.join(@root, "capture.png")
    output = File.join(@root, "composed.png")
    runner.command("magick", "-size", "3024x1964", "xc:#327abe", "-fill", "red",
                   "-draw", "point 1512,982", source)
    original = Digest::SHA256.file(source).hexdigest
    runner.compose_mac(source, output)
    assert_equal [3860, 2320], FastImage.size(output)
    # Native screen pixels must land at the aperture offset without resampling.
    assert_equal "255,0,0", runner.command("magick", output, "-format",
                                          "%[fx:round(255*p{1930,1050}.r)],%[fx:round(255*p{1930,1050}.g)],%[fx:round(255*p{1930,1050}.b)]", "info:").strip
    assert_equal original, Digest::SHA256.file(source).hexdigest
    # The old rectangular placement leaked here, outside the curved bezel.
    assert_equal "0", runner.command("magick", output, "-format", "%[fx:p{418,68}.a]", "info:").strip
    assert_equal "1", runner.command("magick", output, "-format", "%[fx:p{1930,1160}.a]", "info:").strip
    assert_equal "50,122,190", runner.command("magick", output, "-format",
                                             "%[fx:round(255*p{1930,1160}.r)],%[fx:round(255*p{1930,1160}.g)],%[fx:round(255*p{1930,1160}.b)]", "info:").strip
  end

  def test_default_frames_only_include_website_used_scenes
    jobs = ScreenshotFrames.new({}, root: @root).plan
    assert_equal 21, jobs.size
    refute jobs.any? { |job| job[:input].end_with?("/ipad-15/ssh.png", "/iphone-6.3/metrics.png") }
    explicit = ScreenshotFrames.new({ devices: "ipad", scenes: "ssh", locales: "en" }, root: @root).plan
    assert_equal 1, explicit.size
    assert explicit.first[:input].end_with?("/ipad-15/ssh.png")
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
    source = File.join(@root, "review-input/en/iphone-6.3/vault.png")
    png(source, 1206, 2622)
    original_hash = Digest::SHA256.file(source).hexdigest
    runner = ScreenshotFrames.new({ devices: "iphone", scenes: "vault", locales: "en",
                                    input: "review-input", output: "review-output" }, root: @root)
    downloader = Object.new
    downloader.define_singleton_method(:frames_exist?) { true }
    Frameit::FrameDownloader.stub(:templates_path, @templates) do
      Frameit::FrameDownloader.stub(:new, downloader) do
        runner.run do |options|
          assert_equal "iPhone 18 Pro", options.fetch(:force_device_type)
          framefile = JSON.parse(File.read(File.join(options.fetch(:path), "Framefile.json")))
          assert_equal({ "offset" => "+72+69", "width" => 1206 }, framefile.fetch("default").fetch("offset"))
          png(File.join(options.fetch(:path), "iphone_framed.png"), 1350, 2760)
        end
      end
    end
    assert File.exist?(File.join(@root, "review-output/en/iphone-6.3/vault.png"))
    assert_equal original_hash, Digest::SHA256.file(source).hexdigest
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind"))
  end

  def test_rejects_pro_max_sources_before_calling_frameit
    source = File.join(@root, "com.akinokaede.termind/assets/captures/en/iphone-6.3/vault.png")
    png(source, 1320, 2868)
    runner = ScreenshotFrames.new({ devices: "iphone", scenes: "vault", locales: "en" }, root: @root)
    called = false
    assert_raises(RuntimeError) { runner.run { called = true } }
    refute called
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind/assets/device_frames"))
  end

  def test_duo_frames_preserve_native_sources_and_use_each_display_aperture
    templates = File.join(@root, "templates")
    FileUtils.mkdir_p(templates)
    downloader = Object.new
    downloader.define_singleton_method(:frames_exist?) { true }
    expected = {
      "outer" => [[1398, 2034], [1574, 2194], "+88+80", "iPhone Duo Outer"],
      "inner" => [[2853, 2007], [2247, 3093], "+120+120", "iPhone Duo Inner"]
    }
    expected.each do |display, (native, frame, offset, name)|
      device = "iphone-duo-#{display}"
      source = File.join(@root, "input/en/#{device}/vault.png")
      template = File.join(@root, "#{device}.png")
      png(source, *native)
      frame_template(template, *frame)
      source_hash = Digest::SHA256.file(source).hexdigest
      options = { devices: device, scenes: "vault", locales: "en", input: "input", output: "output",
                  "iphone_duo_#{display}_frame".to_sym => template }
      Frameit::FrameDownloader.stub(:templates_path, templates) do
        Frameit::FrameDownloader.stub(:new, downloader) do
          ScreenshotFrames.new(options, root: @root).run do |configuration|
            assert_equal name, configuration.fetch(:force_device_type)
            framefile = JSON.parse(File.read(File.join(configuration.fetch(:path), "Framefile.json")))
            assert_equal({ "offset" => offset, "width" => native.min }, framefile.fetch("default").fetch("offset"))
            assert_equal :landscape_right, configuration.fetch(:force_orientation_block).call(nil) if display == "inner"
            png(File.join(configuration.fetch(:path), "#{device}_framed.png"), *(display == "inner" ? frame.reverse : frame))
          end
        end
      end
      assert_equal source_hash, Digest::SHA256.file(source).hexdigest
      assert_equal(display == "inner" ? frame.reverse : frame, FastImage.size(File.join(@root, "output/en/#{device}/vault.png")))
    end
  end

  def test_missing_duo_template_fails_before_publishing
    runner = ScreenshotFrames.new({ devices: "iphone-duo-inner", locales: "en" }, root: @root)
    error = assert_raises(RuntimeError) { runner.run { flunk "frameit must not start" } }
    assert_includes error.message, "iphone_duo_inner_frame:"
    refute Dir.exist?(File.join(@root, "com.akinokaede.termind/assets/device_frames"))
  end

  def test_missing_frameit_output_keeps_all_existing_outputs_and_sources
    %w[en zh-hans].each do |locale|
      png(File.join(@root, "com.akinokaede.termind/assets/captures/#{locale}/iphone-6.3/vault.png"), 1206, 2622)
    end
    destination = File.join(@root, "com.akinokaede.termind/assets/device_frames/en/iphone-6.3/vault.png")
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, "existing frame")
    source = File.join(@root, "com.akinokaede.termind/assets/captures/en/iphone-6.3/vault.png")
    original_hash = Digest::SHA256.file(source).hexdigest
    runner = ScreenshotFrames.new({ devices: "iphone", scenes: "vault", locales: "en,zh-Hans" }, root: @root)
    downloader = Object.new
    downloader.define_singleton_method(:frames_exist?) { true }
    calls = 0
    Frameit::FrameDownloader.stub(:templates_path, @templates) do
      Frameit::FrameDownloader.stub(:new, downloader) do
        assert_raises(RuntimeError) do
          runner.run do |options|
            calls += 1
            png(File.join(options.fetch(:path), "iphone_framed.png"), 1350, 2760) if calls == 1
            # frameit can log an error and return successfully without an image.
          end
        end
      end
    end
    assert_equal 2, calls
    assert_equal "existing frame", File.read(destination)
    assert_equal original_hash, Digest::SHA256.file(source).hexdigest
    refute File.exist?(destination.sub("/en/", "/zh-hans/"))
  end
end
