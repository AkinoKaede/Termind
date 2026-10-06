require "tmpdir"
require_relative "screenshots"

# frameit owns composition. Only staged copies are resized; source captures are
# read-only, and the website's existing feature/file names remain stable.
class ScreenshotFrames
  DEVICES = %w[iphone ipad mac].freeze
  WEBSITE_SCENES = {
    "iphone" => %w[assistant ssh vault], "ipad" => %w[metrics sftp vault], "mac" => %w[workspace]
  }.freeze

  def initialize(options = {}, root: Screenshots::ROOT)
    @root = root
    @mac_frame = File.expand_path(options[:mac_frame] || ".build/frameit-assets/macbook_pro_template.png", root)
    @ipad_frame = File.expand_path(options[:ipad_frame] || ".build/frameit-assets/ipad-pro-13-m5.png", root)
    selector = Screenshots.new(:ios, {}, environment: {}, root: root)
    @devices = selector.selection(options[:devices], DEVICES, DEVICES, "devices")
    @locales = selector.selection(options[:locales], Screenshots::LOCALES.keys, Screenshots::LOCALES.keys, "locales")
    @scenes = options[:scenes]
    @uses_default_assets = !options[:input] || !options[:output]
    @input = File.expand_path(options[:input] || "#{Screenshots::ASSET_DIRECTORY}/assets/captures", root)
    @output = File.expand_path(options[:output] || "#{Screenshots::ASSET_DIRECTORY}/assets/device_frames", root)
    @jobs = @devices.flat_map do |device|
      scenes = device == "mac" ? ["workspace"] : Screenshots::MOBILE_SCENES
      selected = selector.selection(@scenes, WEBSITE_SCENES.fetch(device), scenes, "#{device} scenes")
      selected.product(@locales).map do |scene, language|
        relative = "#{language.downcase}/#{device}/#{scene}"
        { device: device, input: File.join(@input, "#{relative}.png"),
          output: File.join(@output, "#{relative}.png") }
      end
    end
  end

  def plan
    @jobs
  end

  def run
    Screenshots.require_assets!(@root) if @uses_default_assets
    require "frameit"
    require "fastimage"
    unless Frameit::Devices.const_defined?(:IPAD_PRO_13_CUSTOM)
      Frameit::Devices.const_set(:IPAD_PRO_13_CUSTOM, Frameit::Device.new(
        "ipad-pro-13-custom", "Apple iPad Pro 13-inch (M5)", 20,
        [[2064, 2752], [2752, 2064]], 264, "Space Black", Frameit::Platform::IOS
      ))
    end
    if @devices.include?("ipad") && FastImage.size(@ipad_frame) != [2300, 3000]
      raise "Import the official iPad Pro (M5) 13-inch Space Black portrait PNG first; " \
            "see fastlane/device_frames/README.md or pass ipad_frame:/path/to/frame.png"
    end
    if @devices.include?("mac") && FastImage.size(@mac_frame) != [4260, 2620]
      raise "Import the narrow MacBook Pro template first; see fastlane/device_frames/README.md " \
            "or pass mac_frame:/path/to/frame.png"
    end
    @jobs.each do |job|
      expected = job[:device] == "mac" ? [3024, 1964] : Screenshots::DEVICES.fetch(job[:device]).fetch(:dimensions)
      actual = FastImage.size(job[:input])
      raise "Recapture #{job[:input]}: expected native #{expected.join('x')}, found #{actual.inspect}" unless actual == expected
    end
    directory = File.join(@root, ".build", "fastlane-frames")
    FileUtils.mkdir_p(directory)
    Dir.mktmpdir("run-", directory) do |stage|
      framefile = JSON.parse(File.read(File.join(@root, "fastlane", "Framefile.json")))
      File.write(File.join(stage, "Framefile.json"), JSON.generate(framefile))
      Dir.chdir(stage) do
        downloader = Frameit::FrameDownloader.new
        downloader.download_frames unless downloader.frames_exist?
      end
      if @devices.include?("ipad")
        template = File.join(Frameit::FrameDownloader.templates_path, "Apple iPad Pro 13-inch (M5) Space Black.png")
        FileUtils.cp(@ipad_frame, template)
      end
      # Keep assets below device_frames so frameit never mistakes them for captures.
      pending = @jobs.each_with_index.map do |job, index|
        work = File.join(stage, index.to_s)
        FileUtils.mkdir_p(work)
        source = File.join(work, "#{job[:device]}.png")
        FileUtils.cp(job[:input], source)
        configuration = framefile.merge("default" => {})
        force_device = case job[:device]
                       when "iphone"
                         "iPhone 17 Pro"
                       when "ipad"
                         configuration["default"] = { "offset" => { "offset" => "+118+124", "width" => 2064 } }
                         "iPad Pro 13-inch (M5)"
                       end
        File.write(File.join(work, "Framefile.json"), JSON.generate(configuration))
        frame_options = { path: work, force_device_type: force_device, use_platform: "IOS" }
        frame_options[:force_orientation_block] = ->(_) { :landscape_left } if job[:device] == "ipad"
        rendered = File.join(work, "#{job[:device]}_framed.png")
        if job[:device] == "mac"
          compose_mac(source, rendered)
        else
          yield(frame_options)
        end
        # frameit logs some image errors without failing the lane. Verify output
        # explicitly, and publish nothing unless every requested frame succeeded.
        size = FastImage.size(rendered)
        raise "frameit did not produce a valid frame for #{job[:input]}" unless size && size.all?(&:positive?)
        [rendered, job[:output]]
      end
      pending.each do |rendered, destination|
        FileUtils.mkdir_p(File.dirname(destination))
        temporary = "#{destination}.#{SecureRandom.hex(4)}.tmp"
        begin
          FileUtils.cp(rendered, temporary)
          File.rename(temporary, destination)
        ensure
          FileUtils.rm_f(temporary)
        end
      end
    end
  end

  def compose_mac(source, output)
    # Match the native display aspect ratio to the narrow template aperture.
    # The capture already contains the black camera strip used in full screen.
    command("magick", @mac_frame, "(", source, "-resize", "3454x", ")",
            "-gravity", "northwest", "-geometry", "+403+74", "-compose", "DstOver", "-composite", output)
  end

  def command(*arguments)
    output, status = Open3.capture2e(*arguments)
    raise "#{arguments.join(' ')} failed:\n#{output}" unless status.success?
    output
  end
end
