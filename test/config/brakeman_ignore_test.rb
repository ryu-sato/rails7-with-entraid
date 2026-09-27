require "test_helper"

# config/brakeman.ignore acknowledges that Rails 7.2 is past its end of life
# (a known, accepted risk: .kiro/steering/tech.md). Brakeman's fingerprint for that
# warning does not include the message or the Rails version, so the entry would
# also hide the same warning for any later Rails version. These tests make the
# acknowledgement expire when Rails changes, so someone has to look at it again.
class BrakemanIgnoreTest < ActiveSupport::TestCase
  IGNORE_FILE = Rails.root.join("config/brakeman.ignore")

  def ignored_warnings = JSON.parse(IGNORE_FILE.read).fetch("ignored_warnings")
  def eol_entries = ignored_warnings.select { |warning| warning["check_name"] == "EOLRails" }

  test "every ignored warning carries a note saying why it is accepted" do
    ignored_warnings.each do |warning|
      assert warning["note"].to_s.strip.present?, "#{warning['check_name']} is ignored without a note"
    end
  end

  test "the Rails end-of-life acknowledgement is for the Rails version in use" do
    eol_entries.each do |warning|
      assert_includes warning["message"], "Rails #{Rails.version} ",
                      "config/brakeman.ignore acknowledges an end-of-life warning for another Rails version " \
                      "(now #{Rails.version}). Review it: remove the entry once Rails is upgraded, or re-acknowledge " \
                      "on purpose with `bin/brakeman -I` (with a note)."
    end
  end

  test "only the Rails end-of-life warning is ignored" do
    assert_equal [ "EOLRails" ], ignored_warnings.map { |warning| warning["check_name"] }.uniq
  end
end
