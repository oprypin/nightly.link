struct DelimitedString
  include Enumerable(String)
  include Iterable(String)

  def initialize(@s : String)
  end

  def each(& : String ->)
    @s.each_line do |s|
      yield s
    end
  end

  def each
    @s.each_line
  end

  def includes?(s : String) : Bool
    raise ArgumentError.new(s) if s.byte_index('\n'.ord.to_u8!)
    @s.starts_with?(s += "\n") || @s.includes?(s = "\n" + s)
  end

  def to_s : String
    @s
  end

  struct Builder
    def initialize(@b : String::Builder = String::Builder.new)
    end

    def <<(s : String)
      raise ArgumentError.new(s) if s.byte_index('\n'.ord.to_u8!)
      @b.puts(s)
    end

    def build : DelimitedString
      DelimitedString.new(@b.to_s)
    end
  end

  def self.build(& : Builder ->) : self
    b = Builder.new
    yield builder
    b.build
  end
end
