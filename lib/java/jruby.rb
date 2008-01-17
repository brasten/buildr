require 'java'


# Buildr runs along side a JVM, using either RJB or JRuby.  The Java module allows
# you to access Java classes and create Java objects.
#
# Java classes are accessed as static methods on the Java module, for example:
#   str = Java.java.lang.String.new('hai!')
#   str.toUpperCase
#   => 'HAI!'
#   Java.java.lang.String.isInstance(str)
#   => true
#   Java.com.sun.tools.javac.Main.compile(args)
#
# The classpath attribute allows Buildr to add JARs and directories to the classpath,
# for example, we use it to load Ant and various Ant tasks, code generators, test
# frameworks, and so forth.
#
# When using an artifact specification, Buildr will automatically download and
# install the artifact before adding it to the classpath.
#
# For example, Ant is loaded as follows:
#   Java.classpath << 'org.apache.ant:ant:jar:1.7.0'
#
# Artifacts can only be downloaded after the Buildfile has loaded, giving it
# a chance to specify which remote repositories to use, so adding to classpath
# does not by itself load any libraries.  You must call Java.load before accessing
# any Java classes to give Buildr a chance to load the libraries specified in the
# classpath.
#
# When building an extension, make sure to follow these rules:
# 1. Add to the classpath when the extension is loaded (i.e. in module or class
#    definition), so the first call to Java.load anywhere in the code will include
#    the libraries you specify.
# 2. Call Java.load once before accessing any Java classes, allowing Buildr to
#    set up the classpath.
# 3. Only call Java.load when invoked, otherwise you may end up loading the JVM
#    with a partial classpath, or before all remote repositories are listed.
# 4. Check on a clean build with empty local repository.
module Java

  class << self

    # Returns the classpath, an array listing directories, JAR files and
    # artifacts.  Use when loading the extension to add any additional
    # libraries used by that extension.
    #
    # For example, Ant is loaded as follows:
    #   Java.classpath << 'org.apache.ant:ant:jar:1.7.0'
    def classpath
      @classpath ||= java.lang.System.getProperty('java.class.path').split(':').compact
    end

    # Loads the JVM and all the libraries listed on the classpath.  Call this
    # method before accessing any Java class, but only call it from methods
    # used in the build, giving the Buildfile a chance to load all extensions
    # that append to the classpath and specify which remote repositories to use.
    def load
      return self if @loaded
      cp = Buildr.artifacts(classpath).map(&:to_s).each { |path| file(path).invoke }
      cp.each do |lib|
        if File.file?(lib)
          require lib # JRuby can load jars in runtime
        else
          $CLASSPATH << lib
        end
      end
      load_java_tools      
      @loaded = true
      self
    end

    def load_java_tools
      unless RUBY_PLATFORM =~ /darwin/i
        home = ENV['JAVA_HOME'] or fail 'Are we forgetting something? JAVA_HOME not set.'
        tools = File.expand_path('lib/tools.jar', home)
        raise "Missing #{tools}, perhaps your JAVA_HOME is not correclty set" unless File.file?(tools)
        require tools
      end
      
      str_args = lambda do |obj, method_name|
        (class << obj; self; end).module_eval <<-RUBY
          alias_method :#{method_name}_native, :#{method_name}
          def #{method_name}(args)
            #{method_name}_native(args.to_java(java.lang.String))
          end
        RUBY
      end
      #str_args.call(com.sun.tools.javac.Main, :compile)
      #str_args.call(com.sun.tools.javadoc.Main, :execute)
      #str_args.call(com.sun.tools.apt.Main, :process)
      com.sun.tools.doclets.standard.Standard.new # just load the class
    end

  end

end


module FileUtils
  def touch(list, options = {})
    fu_check_options options, OPT_TABLE['touch']
    list = fu_list(list)
    created = nocreate = options[:nocreate]
    t = options[:mtime]
    if options[:verbose]
      fu_output_message "touch #{nocreate ? ' -c' : ''}#{t ? t.strftime(' -t %Y%m%d%H%M.%S') : ''}#{list.join ' '}"
    end
    t ||= Time.now # Otherwise JRuby breaks, and not in a nice way.
    return if options[:noop]
    list.each do |path|
      created = nocreate
      begin
        File.utime(t, t, path)
      rescue Errno::ENOENT
        raise if created
        File.open(path, 'a') {
          ;
        }
        created = true
        retry if t
      end
    end
  end
  module_function :touch
end


# Misnamed in RC1.
class IO #:nodoc:
  alias :isatty :isatty?
end


module Buildr
  class ZipTask
    # RubyZip doesn't work on JRuby.
    def create_from(file_map) #:nodoc:
      out = Java.java.io.FileOutputStream.new(name)
      zip = Java.java.util.zip.ZipOutputStream.new(out)
      begin
        zip.setLevel compression_level

        seen = {}
        mkpath = lambda do |dir|
          unless dir == '.' || seen[dir]
            mkpath.call File.dirname(dir)
            zip.putNextEntry(Java.java.util.zip.ZipEntry.new(dir + '/'))
            seen[dir] = true
          end
        end

        mkpath.call '' if file_map.empty?
        file_map.each do |path, content|
          mkpath.call File.dirname(path)
          if content.nil? || File.directory?(content.to_s)
            mkpath.call path
          else
            if content.respond_to?(:call)
              io = StringIO.new
              content.call io
              data = io.string.to_java_bytes
            else
              data = File.read(content.to_s).to_java_bytes
            end
            entry = Java.java.util.zip.ZipEntry.new(path)
            entry.setSize(data.length)
            zip.putNextEntry(entry)
            zip.write data
          end
        end
      ensure
        zip.close
      end
    end
  end
end
