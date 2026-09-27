# Application role names held by a user (entra-authorization). Written only by
# Authorization::RoleSync at sign-in. JSON keeps this portable across SQLite
# and PostgreSQL, whichever the app ends up on; existing rows start empty.
class AddRolesToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :roles, :json, null: false, default: []
  end
end
