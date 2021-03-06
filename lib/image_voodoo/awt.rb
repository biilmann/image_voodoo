class ImageVoodoo
  java_import java.awt.RenderingHints
  java_import java.awt.color.ColorSpace
  java_import java.awt.geom.AffineTransform
  java_import java.awt.image.BufferedImage
  java_import java.awt.image.ByteLookupTable
  java_import java.awt.image.ColorConvertOp
  java_import java.awt.image.LookupOp
  java_import java.awt.image.RescaleOp
  java_import java.io.ByteArrayInputStream
  java_import java.io.ByteArrayOutputStream
  java_import javax.imageio.ImageIO
  java_import javax.swing.JFrame

  NEGATIVE_OP = LookupOp.new(ByteLookupTable.new(0, (0...254).to_a.reverse.to_java(:byte)), nil)
  GREY_OP = ColorConvertOp.new(ColorSpace.getInstance(ColorSpace::CS_GRAY), nil)
  ARGB = BufferedImage::TYPE_INT_ARGB
  RGB = BufferedImage::TYPE_INT_RGB
  SCALE_SMOOTH = java.awt.Image::SCALE_SMOOTH

  #
  # AWT-only (experimental)
  # Add a border to the image and yield/return a new image.  The following
  # options are supported:
  #   - width: How thick is the border (default: 3)
  #   - color: Which color is the border (in rrggbb hex value) 
  #   - style: etched, raised, plain (default: plain)
  #
  def add_border(options = {})
    border_width = options[:width].to_i || 2
    color = hex_to_color(options[:color]) || hex_to_color("000000")
    style = options[:style]
    style = nil if style.to_sym == :plain
    new_width, new_height = width + 2*border_width, height + 2*border_width
    target = paint(BufferedImage.new(new_width, new_height, color_type)) do |g|
      g.color = color
      if style
        raised = style.to_sym == :raised ? true : false
        g.fill3DRect(0, 0, new_width, new_height, raised)
      else
        g.fill_rect(0, 0, new_width, new_height)
      end
      g.draw_image(@src, nil, border_width, border_width)
    end
    block_given? ? yield(target) : target
  end

  def adjust_brightness_impl(scale, offset)
    transform(RescaleOp.new(scale, offset, nil))
  end

  # AWT-only
  def alpha_impl(rgb)
    color = hex_to_color(rgb)
    target = paint(BufferedImage.new(width, height, ARGB)) do |g|
      g.set_composite(java.awt.AlphaComposite::Src)
      g.draw_image(@src, nil, 0, 0)
      0.upto(height-1) do |i|
        0.upto(width-1) do |j|
          target.setRGB(j, i, 0x8F1C1C) if target.getRGB(j, i) == color.getRGB
        end
      end
    end
  end

  def bytes_impl(format)
    out = ByteArrayOutputStream.new
    ImageIO.write(@src, format, out)
    out.to_byte_array
  end

  def flip_horizontally_impl
    paint {|g| g.draw_image @src, 0, 0, width, height, width, 0, 0, height, nil}
  end

  def flip_vertically_impl
    paint {|g| g.draw_image @src, 0, 0, width, height, 0, height, width, 0, nil}
  end

  def greyscale_impl
    transform(GREY_OP)
  end

  def negative_impl
    transform(NEGATIVE_OP)
  end

  def resize_impl(width, height)
    paint(BufferedImage.new(width, height, color_type)) do |g|
      scaled_image = @src.get_scaled_instance width, height, SCALE_SMOOTH
      g.draw_image scaled_image, 0, 0, nil
    end
  end

  #
  # Save using the format string (jpg, gif, etc..) to the open Java File
  # instance passed in.
  #
  def save_impl(format, file)
    ImageIO.write(@src, format, file)
  end

  def with_crop_impl(left, top, right, bottom)
    ImageVoodoo.new @src.get_subimage(left, top, right-left, bottom-top)
  end

  # 
  # A simple swing wrapper around an image voodoo object.
  #
  class JImagePanel < javax.swing.JPanel
    def initialize(image, x=0, y=0)
      super()
      @image, @x, @y = image, x, y
    end

    def image=(image)
      @image = image
      invalidate
    end

    def getPreferredSize
      java.awt.Dimension.new(@image.width, @image.height)
    end

    def paintComponent(graphics)
      graphics.draw_image(@image.to_java, @x, @y, nil)
    end
  end

  # Internal class for closing preview window
  class WindowClosed
    def initialize(block = nil)
      @block = block || proc { java.lang.System.exit(0) }
    end
    def method_missing(meth,*args); end
    def windowClosing(event); @block.call; end
  end

  #
  # Creates a viewable frame displaying current image within it.
  #
  def preview(&block)
    frame = JFrame.new("Preview")
    frame.add_window_listener WindowClosed.new(block)
    frame.set_bounds 0, 0, width + 20, height + 40
    frame.add JImagePanel.new(self, 10, 10)
    frame.visible = true
  end

  #
  # TODO: Figure out how to determine whether source has alpha or not
  # Experimental: Read an image from the url source and yield/return that
  # image.
  #
  def self.from_url(source)
    url = java.net.URL.new(source)
    image = java.awt.Toolkit.default_toolkit.create_image(url)
    tracker = java.awt.MediaTracker.new(java.awt.Label.new(""))
    tracker.addImage(image, 0);
    tracker.waitForID(0)
    target = paint(BufferedImage.new(image.width, image.height, RGB)) do |g| 
      g.draw_image image, 0, 0, nil
    end
    block_given? ? yield(target) : target
  rescue java.io.IOException, java.net.MalformedURLException
    raise ArgumentError.new "Trouble retrieving image: #{$!.message}"
  end

  def self.with_image_impl(file)
    buffered_image = ImageIO.read(file)
    buffered_image ? ImageVoodoo.new(buffered_image) : nil
  end

  def self.with_bytes_impl(bytes)
    ImageVoodoo.new ImageIO.read(ByteArrayInputStream.new(bytes))
  end

  private

  #
  # Converts a RGB hex value into a java.awt.Color object or dies trying
  # with an ArgumentError.
  #
  def hex_to_color(rgb)
    raise ArgumentError.new "hex rrggbb needed" if rgb !~ /[[:xdigit:]]{6,6}/

    java.awt.Color.new(rgb[0,2].to_i(16), rgb[2,2].to_i(16), rgb[4,2].to_i(16))
  end

  # 
  # Determines the best colorspace for a new image based on whether the
  # existing image contains an alpha channel or not.
  #
  def color_type
    @src.color_model.has_alpha ? ARGB : RGB
  end

  # 
  # Make a duplicate of the underlying Java src image
  #
  def dup_src
    BufferedImage.new width, height, color_type
  end

  #
  # Do simple AWT operation transformation to target.
  #
  def transform(operation, target=dup_src)
    paint(target) do |g|
      g.draw_image(@src, 0, 0, nil)
      g.draw_image(operation.filter(target, nil), 0, 0, nil)
    end
  end

  #
  # DRY up drawing setup+teardown
  # 
  def paint(src=dup_src)
    yield src.graphics
    src.graphics.dispose
    ImageVoodoo.new src
  end
end
