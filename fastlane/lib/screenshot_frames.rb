require "tmpdir"
require_relative "screenshots"

# frameit owns composition. Only staged copies are resized; source captures are
# read-only, and the website's existing feature/file names remain stable.
class ScreenshotFrames
  DEVICES = %w[iphone iphone-duo-outer iphone-duo-inner ipad mac].freeze
  CUSTOM_FRAMES = {
    "iphone" => { name: "iPhone 18 Pro Max", size: [1470, 3000], offset: "+75+66", width: 1320,
                  color: "Silver", template: "iphone-18-pro-max" },
    "iphone-duo-outer" => { name: "iPhone Duo Outer", size: [1574, 2194], offset: "+88+80", width: 1398, color: "Star White" },
    "iphone-duo-inner" => { name: "iPhone Duo Inner", size: [2247, 3093], offset: "+120+120", width: 2007, color: "Star White" }
  }.freeze
  WEBSITE_SCENES = {
    "iphone" => %w[assistant ssh vault], "ipad" => %w[metrics sftp vault], "mac" => %w[workspace],
    "iphone-duo-outer" => Screenshots::MOBILE_SCENES, "iphone-duo-inner" => Screenshots::MOBILE_SCENES
  }.freeze

  def initialize(options = {}, root: Screenshots::ROOT)
    @root = root
    @mac_frame = File.expand_path(options[:mac_frame] || ".build/frameit-assets/macbook_pro_template.png", root)
    @ipad_frame = File.expand_path(options[:ipad_frame] || ".build/frameit-assets/ipad-pro-13-m5.png", root)
    @custom_frames = CUSTOM_FRAMES.to_h do |device, specification|
      option = device.tr("-", "_").concat("_frame").to_sym
      [device, File.expand_path(options[option] || ".build/frameit-assets/#{specification[:template] || device}.png", root)]
    end
    selector = Screenshots.new(:ios, {}, environment: {}, root: root)
    @devices = selector.selection(options[:devices], %w[iphone ipad mac], DEVICES, "devices")
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
    (@devices & CUSTOM_FRAMES.keys).each do |device|
      specification = CUSTOM_FRAMES.fetch(device)
      unless FastImage.size(@custom_frames.fetch(device)) == specification.fetch(:size)
        raise "Import the official #{specification.fetch(:name)} #{specification.fetch(:color)} portrait PNG first; " \
              "see Scripts/ASSET_WORKFLOW.md or pass #{device.tr('-', '_')}_frame:/path/to/frame.png"
      end
      constant = device.tr("-", "_").upcase
      unless Frameit::Devices.const_defined?(constant)
        dimensions = Screenshots::DEVICES.fetch(device).fetch(:dimensions).sort
        Frameit::Devices.const_set(constant, Frameit::Device.new(
          device, "Apple #{specification.fetch(:name)}", 21,
          [dimensions, dimensions.reverse], 460, specification.fetch(:color), Frameit::Platform::IOS
        ))
      end
    end
    unless Frameit::Devices.const_defined?(:IPAD_PRO_13_CUSTOM)
      Frameit::Devices.const_set(:IPAD_PRO_13_CUSTOM, Frameit::Device.new(
        "ipad-pro-13-custom", "Apple iPad Pro 13-inch (M5)", 20,
        [[2064, 2752], [2752, 2064]], 264, "Space Black", Frameit::Platform::IOS
      ))
    end
    if @devices.include?("ipad") && FastImage.size(@ipad_frame) != [2300, 3000]
      raise "Import the official iPad Pro (M5) 13-inch Space Black portrait PNG first; " \
            "see Scripts/ASSET_WORKFLOW.md or pass ipad_frame:/path/to/frame.png"
    end
    if @devices.include?("mac") && FastImage.size(@mac_frame) != [4260, 2620]
      raise "Import the narrow MacBook Pro template first; see Scripts/ASSET_WORKFLOW.md " \
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
      (@devices & CUSTOM_FRAMES.keys).each do |device|
        specification = CUSTOM_FRAMES.fetch(device)
        name = "Apple #{specification.fetch(:name)} #{specification.fetch(:color)}.png"
        FileUtils.cp(@custom_frames.fetch(device), File.join(Frameit::FrameDownloader.templates_path, name))
      end
      # Keep assets below device_frames so frameit never mistakes them for captures.
      pending = @jobs.each_with_index.map do |job, index|
        work = File.join(stage, index.to_s)
        FileUtils.mkdir_p(work)
        source = File.join(work, "#{job[:device]}.png")
        FileUtils.cp(job[:input], source)
        configuration = framefile.merge("default" => {})
        force_device = case job[:device]
                       when *CUSTOM_FRAMES.keys
                         specification = CUSTOM_FRAMES.fetch(job[:device])
                         configuration["default"] = { "offset" => {
                           "offset" => specification.fetch(:offset), "width" => specification.fetch(:width)
                         } }
                         mask_screen(source, @custom_frames.fetch(job[:device]), specification.fetch(:offset),
                                     rotation: job[:device] == "iphone-duo-inner" ? 90 : 0)
                         specification.fetch(:name)
                       when "ipad"
                         configuration["default"] = { "offset" => { "offset" => "+118+124", "width" => 2064 } }
                         mask_screen(source, @ipad_frame, "+118+124", rotation: -90)
                         "iPad Pro 13-inch (M5)"
                       end
        File.write(File.join(work, "Framefile.json"), JSON.generate(configuration))
        frame_options = { path: work, force_device_type: force_device, use_platform: "IOS" }
        if job[:device] == "iphone-duo-inner"
          frame_options[:force_orientation_block] = ->(_) { :landscape_right }
        elsif job[:device] == "ipad"
          frame_options[:force_orientation_block] = ->(_) { :landscape_left }
        end
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
    # The official M5 16-inch aperture is 3456x2234 after removing the
    # template's 220px transparent top margin. Preserve the capture's aspect
    # ratio and trim only 11px from its black full-screen camera strip.
    Dir.mktmpdir("mac-screen-", File.dirname(output)) do |directory|
      screen = File.join(directory, "screen.png")
      command("magick", source, "-resize", "3456x", "-gravity", "south",
              "-extent", "3456x2234", screen)
      mask_screen(screen, @mac_frame, "+402+83")
      command("magick", @mac_frame, "-colorspace", "sRGB", screen, "-gravity", "northwest", "-geometry", "+402+83",
              "-compose", "DstOver", "-composite", output)
    end
  end

  def mask_screen(source, template, offset, rotation: 0)
    # The template has transparent pixels both inside the display and outside
    # the device. Its opaque bezel separates them. Remove the exterior region
    # before framing so rectangular capture corners cannot escape the bezel.
    mask = File.join(File.dirname(source), "screen-mask.png")
    command("magick", template, "-alpha", "extract", "-threshold", "99%", "-negate",
            "-fill", "black", "-draw", "color 0,0 floodfill", mask)
    center = command("magick", mask, "-format", "%[fx:p{w/2,h/2}]", "info:").strip
    raise "No enclosed screen aperture in #{template}" unless center == "1"

    dimensions = FastImage.size(source)
    dimensions = dimensions.reverse unless rotation.zero?
    arguments = ["magick", mask, "-crop", "#{dimensions.join('x')}#{offset}", "+repage"]
    arguments += ["-rotate", rotation.to_s] unless rotation.zero?
    command(*arguments, mask)
    command("magick", source, "-alpha", "set", "(", mask, "-alpha", "copy", ")",
            "-compose", "DstIn", "-composite", source)
    FileUtils.rm_f(mask)
  end

  def command(*arguments)
    output, status = Open3.capture2e(*arguments)
    raise "#{arguments.join(' ')} failed:\n#{output}" unless status.success?
    output
  end
end
