require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"

# Release orchestration only. Scene fixtures and rendering assertions remain in
# TFMTests/TFITests; scan owns all Xcode build/test invocations.
class Screenshots
  ROOT = File.expand_path("../..", __dir__)
  ASSET_DIRECTORY = "com.akinokaede.termind".freeze

  def self.require_assets!(root)
    directory = File.join(root, ASSET_DIRECTORY)
    return if File.exist?(File.join(directory, ".git")) && File.directory?(File.join(directory, "assets"))

    raise "Initialize the website and assets first: git submodule update --init com.akinokaede.termind"
  end

  LOCALES = { "en" => ["US", "en_US"], "zh-Hans" => ["CN", "zh_CN"], "zh-Hant" => ["TW", "zh_TW"] }.freeze
  MAC_SCENES = {
    "hosts" => ["vault", "mac"],
    "workspace" => ["workspace", "mac"],
    "agent" => ["assistant", "mac"],
    "command" => ["command-generator", "mac"],
    "metrics" => ["metrics", "mac-overview"]
  }.freeze
  MOBILE_SCENES = %w[vault sftp ssh metrics assistant].freeze
  DEVICES = {
    "iphone" => { name: "iPhone 17 Pro Max", type: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
                  dimensions: [1320, 2868] },
    "ipad" => { name: "iPad Pro 13-inch (M5)", type: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
                dimensions: [2752, 2064] }
  }.freeze

  def initialize(platform, options = {}, environment: ENV, root: ROOT)
    raise ArgumentError, "Unsupported platform: #{platform}" unless %i[mac ios].include?(platform)

    @platform = platform
    @root = root
    @scheme = platform == :mac ? "TFM" : "TFI"
    prefix = platform == :mac ? "TERMIND_MAC_SCREENSHOT" : "TERMIND_SCREENSHOT"
    @scenes = selection(options[:scenes] || environment["#{prefix}_SCENES"],
                        platform == :mac ? ["workspace"] : MOBILE_SCENES,
                        platform == :mac ? MAC_SCENES.keys : MOBILE_SCENES, "scenes")
    @locales = selection(options[:locales] || environment["#{prefix}_LOCALES"], LOCALES.keys, LOCALES.keys, "locales")
    @devices = platform == :mac ? ["mac"] : selection(
      options[:devices] || environment["TERMIND_SCREENSHOT_DEVICES"], DEVICES.keys, DEVICES.keys, "devices"
    )
    @runtime = options[:runtime] || environment["TERMIND_SCREENSHOT_RUNTIME"] || "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    if platform == :ios && !@runtime.match?(/\Acom\.apple\.CoreSimulator\.SimRuntime\.iOS-27-\d+(?:-\d+)?\z/)
      raise ArgumentError, "Screenshots require an iOS/iPadOS 27 runtime: #{@runtime}"
    end
    @default_output = !options[:output]
    @output = File.expand_path(options[:output] || "#{ASSET_DIRECTORY}/assets/captures", root)
    @derived = File.join(root, ".build", "fastlane-screenshots", platform.to_s)
    @run_id = "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}"
    @run_directory = File.join(@derived, "runs", @run_id)
    @backup = File.join(root, ".build", "screenshot-backups", @run_id)
  end

  def plan
    { platform: @platform, scheme: @scheme, scenes: @scenes, locales: @locales,
      devices: @devices, device_specs: @platform == :ios ? DEVICES.slice(*@devices) : nil, runtime: @platform == :ios ? @runtime : nil,
      output: @output, captures: @scenes.size * @locales.size * @devices.size }
  end

  def run(&scan)
    self.class.require_assets!(@root) if @default_output
    @scan = scan
    FileUtils.mkdir_p(@derived)
    # Shared products and simulator presentation cannot be used by two runners.
    File.open(File.join(@root, ".build", "fastlane-screenshots", "capture.lock"), "w") do |lock|
      raise "Another screenshot lane is running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      if @platform == :mac
        version = command("sw_vers", "-productVersion").strip
        raise "Mac screenshots require macOS 27.x; found #{version}" unless version.start_with?("27.")
        destination = "platform=macOS,arch=arm64"
        build(destination)
        @scenes.product(@locales).each { |scene, language| capture_mac(scene, language, destination) }
      else
        devices = find_devices
        build("id=#{devices.values.first.fetch('udid')}")
        devices.each do |device, simulator|
          @locales.each { |language| capture_mobile(device, simulator, language) }
        end
      end
    end
    puts "Screenshots written to #{@output}; backups and SHA-256 manifest: #{@backup}"
  end

  def selection(value, defaults, allowed, label)
    values = value.nil? || value.empty? ? defaults : value.split(",", -1)
    if values.empty? || values.uniq != values || (values - allowed).any?
      raise ArgumentError, "Unsupported or duplicate #{label}: #{values.join(',')}; choose #{allowed.join(',')}"
    end
    values
  end

  def scan_options(destination, label)
    {
      project: File.join(@root, "Termind.xcodeproj"), scheme: @scheme, configuration: "Debug",
      destination: destination, derived_data_path: @derived,
      xcargs: "-onlyUsePackageVersionsFromResolvedFile -collect-test-diagnostics never",
      skip_package_dependencies_resolution: true, disable_package_automatic_updates: true,
      skip_detect_devices: true, parallel_testing: false, disable_concurrent_testing: true,
      number_of_retries: 0, skip_slack: true, xcodebuild_formatter: "",
      suppress_xcode_output: true, output_types: "",
      buildlog_path: File.join(@run_directory, label, "logs"),
      output_directory: File.join(@run_directory, label),
      app_name: "Termind"
    }
  end

  def build(destination)
    @scan.call(scan_options(destination, "build").merge(build_for_testing: true))
    files = Dir.glob(File.join(@derived, "Build", "Products", "#{@scheme}_*.xctestrun"))
    raise "Expected one generated #{@scheme} xctestrun, found #{files.size}" unless files.size == 1
    @source_xctestrun = files.first
  end

  # Handle both legacy and test-plan xctestrun formats. Keep the copy beside the
  # original so __TESTROOT__ references continue to resolve to Build/Products.
  def configure_xctestrun(document, language, environment, arguments)
    targets = if document.key?("TestConfigurations")
                document.fetch("TestConfigurations").flat_map { |configuration| configuration.fetch("TestTargets") }
              else
                [document.fetch("#{@scheme}Tests")]
              end
    targets = targets.select { |target| !target.key?("BlueprintName") || target["BlueprintName"] == "#{@scheme}Tests" }
    raise "Missing #{@scheme}Tests in xctestrun" if targets.empty?
    targets.each do |target|
      target["EnvironmentVariables"] = target.fetch("EnvironmentVariables", {}).merge(environment)
      target["TestLanguage"] = language
      target["TestRegion"] = LOCALES.fetch(language).first
      target["CommandLineArguments"] = arguments + ["-AppleLanguages", "(#{language})", "-AppleLocale", LOCALES.fetch(language).last]
    end
    document
  end

  def test_configuration(language, label, environment, arguments = [])
    document = JSON.parse(command("plutil", "-convert", "json", "-o", "-", @source_xctestrun))
    configure_xctestrun(document, language, environment, arguments)
    path = File.join(File.dirname(@source_xctestrun), "Screenshots-#{@scheme}-#{@run_id}-#{label}.xctestrun")
    File.write(path, JSON.generate(document))
    command("plutil", "-convert", "xml1", path)
    path
  end

  # Capture alongside scan without bypassing its exit-status checking. The
  # fixture's own timeout makes capture failures fail the test as well.
  def capture_during_test(options)
    stopped = false
    capture_error = nil
    watcher = Thread.new do
      until stopped
        yield
        sleep 0.05
      end
    rescue StandardError => error
      capture_error = error
    end
    begin
      @scan.call(options)
    ensure
      stopped = true
      watcher.join
      warn "System capture failed: #{capture_error.message}" if capture_error
    end
    raise capture_error if capture_error
  end

  def capture_mac(scene, language, destination)
    label = "#{scene}-#{language}"
    xctestrun = test_configuration(language, label, { "TERMIND_MAC_SCREENSHOTS" => "1" },
                                  ["--termind-demo=#{scene}:#{language}", "-statusBar.expanded", "YES"])
    options = scan_options(destination, label).merge(
      xctestrun: xctestrun, only_testing: ["TFMTests/MacScreenshotTests"], test_without_building: true
    )
    captured = File.join(@run_directory, "#{label}.png")
    did_capture = false
    native_size = nil
    capture_during_test(options) do
      next if did_capture
      log = File.join(options.fetch(:buildlog_path), "Termind-TFM.log")
      next unless File.exist?(log)
      payload = File.read(log)[/TERMIND_MAC_SCREENSHOT_READY ([^\r\n]+)/, 1]
      next unless payload
      ready_scene, ready_language, window, token, active, key, screen_width, screen_height = payload.split("\t")
      unless ready_scene == scene && ready_language == language && window.match?(/\A\d+\z/) &&
             !token.to_s.empty? && active == "active" && key == "key"
        raise "Capture window was not ready and focused: #{payload}"
      end
      native_size = [Integer(screen_width), Integer(screen_height)]
      raise "Invalid capture size" unless native_size.all?(&:positive?)
      command("screencapture", "-l", window, "-o", captured)
      did_capture = true
    end
    raise "No focused-window capture received for #{label}" unless did_capture
    feature, prefix = MAC_SCENES.fetch(scene)
    actual = dimensions(captured)
    width, height = native_size
    if scene == "workspace"
      # Full-screen windows can exclude the camera strip. Never capture personal UI.
      unless actual[0] == width && actual[1] <= height && height - actual[1] <= 160
        raise "Unexpected full-screen capture #{actual.inspect}; built-in display is #{native_size.inspect}"
      end
      if actual != native_size
        command("magick", captured, "-background", "black", "-gravity", "south", "-extent", "#{width}x#{height}", captured)
      end
    elsif actual == [width + 4, height + 4]
      command("sips", "-c", height.to_s, width.to_s, captured)
    end
    validate_dimensions(captured, native_size)
    promote([[captured, "#{language.downcase}/mac/#{prefix == 'mac-overview' ? 'metrics_overview' : feature.tr('-', '_')}.png"]])
  ensure
    FileUtils.rm_f(xctestrun) if xctestrun
  end

  def find_devices
    available = JSON.parse(command("xcrun", "simctl", "list", "devices", "available", "-j"))
                    .fetch("devices").fetch(@runtime, [])
    @devices.to_h do |device|
      specification = DEVICES.fetch(device)
      matches = available.select do |candidate|
        candidate.fetch("name") == specification.fetch(:name) &&
          candidate.fetch("deviceTypeIdentifier") == specification.fetch(:type)
      end
      unless matches.size == 1
        raise "Expected one available #{specification.fetch(:name)} (#{@runtime}), found #{matches.size}. " \
              "Create it with: xcrun simctl create '#{specification.fetch(:name)}' #{specification.fetch(:type)} #{@runtime}"
      end
      [device, matches.first]
    end
  end

  def capture_mobile(device, simulator, language)
    id = simulator.fetch("udid")
    label = "#{device}-#{language}"
    command("xcrun", "simctl", "boot", id) unless simulator.fetch("state") == "Booted"
    command("xcrun", "simctl", "bootstatus", id, "-b")
    simulator["state"] = "Booted"
    if device == "ipad"
      command("xcrun", "devicectl", "device", "orientation", "set", "--device", id, "landscapeLeft")
      sleep 2
    end
    command("xcrun", "simctl", "status_bar", id, "override", "--time", "9:41", "--batteryState", "discharging",
            "--batteryLevel", "80", "--wifiBars", "3", "--cellularBars", "4")
    capture_id = SecureRandom.uuid
    xctestrun = test_configuration(language, label, {
      "TERMIND_SCREENSHOTS" => "1", "TERMIND_SCREENSHOT_SYSTEM_CAPTURE" => "1",
      "TERMIND_SCREENSHOT_LOCALE" => language, "TERMIND_SCREENSHOT_CAPTURE_ID" => capture_id,
      "TERMIND_SCREENSHOT_SCENES" => @scenes.join(",")
    })
    options = scan_options("id=#{id}", label).merge(
      xctestrun: xctestrun, only_testing: ["TFITests/MobileScreenshotTests"], test_without_building: true
    )
    captures = {}
    tokens = []
    capture_during_test(options) do
      # XCTest may reinstall the host between locales and replace its data container.
      container, status = Open3.capture2e("xcrun", "simctl", "get_app_container", id, "com.akinokaede.termind", "data")
      next unless status.success?
      control = File.join(container.strip, "Documents", "screenshot-capture-control")
      ready = File.join(control, "ready")
      next unless File.exist?(ready)
      feature, ready_device, locale, token, request_id = File.read(ready).strip.split("\t")
      next unless request_id == capture_id && !tokens.include?(token)
      unless @scenes.include?(feature) && ready_device == device && locale == language.downcase &&
             token.to_s.match?(/\A[0-9A-Fa-f-]{36}\z/) && !captures.key?(feature)
        raise "Unexpected or duplicate screenshot request: #{File.read(ready)}"
      end
      captured = File.join(@run_directory, "#{label}-#{feature}.png")
      if device == "ipad"
        command("xcrun", "devicectl", "device", "capture", "screenshot", "--device", id, "--destination", captured)
      else
        command("xcrun", "simctl", "io", id, "screenshot", "--type=png", captured)
      end
      validate_dimensions(captured, DEVICES.fetch(device).fetch(:dimensions))
      captures[feature] = [captured, "#{locale}/#{device}/#{feature}.png"]
      tokens << token
      FileUtils.touch(File.join(control, "ack-#{token}"))
    end
    raise "Expected #{@scenes.join(',')}, received #{captures.keys.join(',')}" unless captures.keys.sort == @scenes.sort
    promote(captures.values)
  ensure
    FileUtils.rm_f(xctestrun) if xctestrun
    # Cleanup must not hide the original scan/capture failure.
    if id
      output, status = Open3.capture2e("xcrun", "simctl", "status_bar", id, "clear")
      warn output unless status.success?
    end
  end

  def dimensions(path)
    output = command("sips", "-g", "pixelWidth", "-g", "pixelHeight", path)
    [output[/pixelWidth: (\d+)/, 1].to_i, output[/pixelHeight: (\d+)/, 1].to_i]
  end

  def validate_dimensions(path, expected)
    actual = dimensions(path)
    raise "Unexpected screenshot dimensions for #{path}: #{actual.join('x')}, expected #{expected.join('x')}" unless actual == expected
  end

  # Only publish after scan and every expected capture have succeeded. Preserve
  # originals and their hashes before replacing any selected source.
  def promote(captures)
    self.class.require_assets!(@root) if @default_output
    captures.each do |source, relative|
      raise "Missing capture: #{source}" unless File.file?(source)
      destination = File.join(@output, relative)
      next unless File.exist?(destination)
      backup = File.join(@backup, relative)
      FileUtils.mkdir_p(File.dirname(backup))
      FileUtils.cp(destination, backup)
      File.open(File.join(@backup, "SHA256SUMS"), "a") do |manifest|
        manifest.puts "#{Digest::SHA256.file(backup).hexdigest}  #{relative}"
      end
    end
    captures.each do |source, relative|
      destination = File.join(@output, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = "#{destination}.#{@run_id}.tmp"
      begin
        FileUtils.cp(source, temporary)
        File.rename(temporary, destination)
      ensure
        FileUtils.rm_f(temporary)
      end
      puts "Captured #{relative}"
    end
  end

  def command(*arguments)
    output, status = Open3.capture2e(*arguments)
    raise "#{arguments.join(' ')} failed (#{status.exitstatus}):\n#{output}" unless status.success?
    output
  end
end
