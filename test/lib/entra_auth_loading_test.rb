require "test_helper"
require "open3"
require "tmpdir"

class EntraAuthLoadingTest < ActiveSupport::TestCase
  ENTRY = Rails.root.join("lib/entra_auth.rb")
  ROOT = Rails.root.to_s

  test "EntraAuth namespace is defined at boot" do
    assert defined?(EntraAuth), "EntraAuth should be defined"
    assert_kind_of Module, EntraAuth
  end

  test "lib/entra_auth is not managed by Zeitwerk" do
    dir = Rails.root.join("lib/entra_auth").to_s
    assert_not_includes Rails.autoloaders.main.dirs, dir
  end

  test "entry requires every file under lib/entra_auth in sorted order without editing the entry" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p("#{tmp}/lib/entra_auth")
      FileUtils.cp(ENTRY, "#{tmp}/lib/entra_auth.rb")
      File.write("#{tmp}/lib/entra_auth/b_second.rb", "($entra_order ||= []) << :b\n")
      File.write("#{tmp}/lib/entra_auth/a_first.rb", "($entra_order ||= []) << :a\n")
      script = <<~RUBY
        $LOAD_PATH.unshift("#{tmp}/lib")
        require "entra_auth"
        print EntraAuth.name, ":", $entra_order.inspect
      RUBY
      out, status = Open3.capture2e("ruby", "-e", script)
      assert status.success?, out
      assert_equal "EntraAuth:[:a, :b]", out
    end
  end

  test "entry loads when lib/entra_auth is empty" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p("#{tmp}/lib/entra_auth")
      FileUtils.cp(ENTRY, "#{tmp}/lib/entra_auth.rb")
      out, status = Open3.capture2e("ruby", "-e", %(
        $LOAD_PATH.unshift("#{tmp}/lib"); require "entra_auth"; print EntraAuth.name))
      assert status.success?, out
      assert_equal "EntraAuth", out
    end
  end
end
