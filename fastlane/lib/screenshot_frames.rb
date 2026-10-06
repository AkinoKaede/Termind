require "tmpdir"
require_relative "screenshots"

# frameit owns composition. Only staged copies are resized; source captures are
# read-only, and the website's existing feature/file names remain stable.
class ScreenshotFrames
  DEVICES = %w[iphone ipad mac].freeze

  module MacFrameDetection
    def mac?
      device.id == "mac"
    end
  end

  module MacFrameBackground
    attr_accessor :top_space_above_device

    # This lane composes a native window on a prepared laptop background, with
    # no title layout. Avoid the mobile padding/density path (Mac density is nil).
    def should_skip?
      false
    end

    def complex_framing
      put_device_into_background(generate_background)
    end

    def generate_background
      MiniMagick::Image.open(@config.fetch("background"))
    end
  end

  def initialize(options = {}, root: Screenshots::ROOT)
    @root = root
    @ipad_frame = File.expand_path(options[:ipad_frame] || ".build/frameit-assets/ipad-pro-13-m5.png", root)
    selector = Screenshots.new(:ios, {}, environment: {}, root: root)
    @devices = selector.selection(options[:devices], DEVICES, DEVICES, "devices")
    @locales = selector.selection(options[:locales], Screenshots::LOCALES.keys, Screenshots::LOCALES.keys, "locales")
    @scenes = options[:scenes]
    @input = File.expand_path(options[:input] || "Marketing/Screenshots/Captures", root)
    @output = File.expand_path(options[:output] || "Marketing/Screenshots/DeviceFrames", root)
    @jobs = @devices.flat_map do |device|
      scenes = device == "mac" ? ["workspace"] : Screenshots::MOBILE_SCENES
      selected = selector.selection(@scenes, scenes, scenes, "#{device} scenes")
      selected.product(@locales).map do |scene, language|
        relative = "#{scene}/#{device}-#{language.downcase}"
        { device: device, input: File.join(@input, "#{relative}.png"),
          output: File.join(@output, "#{relative}-framed.png") }
      end
    end
  end

  def plan
    @jobs
  end

  def run
    require "frameit"
    require "fastimage"
    # fastlane 2.240.1 compares the full name ("Apple MacBook") with
    # "MacBook", which incorrectly selects the mobile editor for Mac frames.
    unless Frameit::Screenshot.ancestors.include?(MacFrameDetection)
      Frameit::Screenshot.prepend(MacFrameDetection)
      # The same release's Mac editor still calls the removed fetch_config API.
      Frameit::MacEditor.prepend(MacFrameBackground)
    end
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
    @jobs.each do |job|
      expected = job[:device] == "mac" ? [2360, 1480] : Screenshots::DEVICES.fetch(job[:device]).fetch(:dimensions)
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
      background = prepare_mac_background(stage) if @devices.include?("mac")
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
                       when "mac"
                         configuration["default"] = {
                           "background" => Pathname.new(background).relative_path_from(Pathname.new(work)).to_s,
                           "offset" => { "offset" => "+570+190", "width" => 2770, "titleHeight" => 0 }
                         }
                         "MacBook"
                       end
        File.write(File.join(work, "Framefile.json"), JSON.generate(configuration))
        frame_options = { path: work, force_device_type: force_device, use_platform: "IOS" }
        frame_options[:force_orientation_block] = ->(_) { :landscape_left } if job[:device] == "ipad"
        yield(frame_options)
        rendered = File.join(work, "#{job[:device]}_framed.png")
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

  def prepare_mac_background(stage)
    assets = File.join(stage, "device_frames")
    FileUtils.mkdir_p(assets)
    background = File.join(assets, "mac-background.png")
    template = File.join(Frameit::FrameDownloader.templates_path, "Apple Macbook Pro 16 Space Gray.png")
    # An owned gradient fills the display; frameit places the native window into
    # this MacBook background using the Framefile offset and width above.
    command("magick", template, "(", "-size", "3072x1920", "gradient:#164c64-#072337", ")",
            "-geometry", "+419+98", "-compose", "DstOver", "-composite", background)
    background
  end

  def command(*arguments)
    output, status = Open3.capture2e(*arguments)
    raise "#{arguments.join(' ')} failed:\n#{output}" unless status.success?
    output
  end
end
