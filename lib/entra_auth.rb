# Entry point of the Entra ID authentication library.
# lib/entra_auth is excluded from Zeitwerk (see config/application.rb);
# every file under lib/entra_auth is required here in sorted order,
# so adding a component only requires adding a file.
module EntraAuth
end

Dir[File.join(__dir__, "entra_auth", "*.rb")].sort.each { |file| require file }
