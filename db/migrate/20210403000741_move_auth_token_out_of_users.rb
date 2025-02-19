class MoveAuthTokenOutOfUsers < ActiveRecord::Migration[4.2]
  def up
    create_table :auth_tokens do |t|
      t.string          :encrypted_authentication_token,  null: false,  limit: 255
      t.string	        :encrypted_authentication_token_iv, limit: 255
      t.datetime        :auth_token_expiry,               null: false
    end
    add_reference   :auth_tokens, :user, index: true

    remove_column :users, :authentication_token
    remove_column :users, :auth_token_expiry
  end

  def down
    add_column :users, :authentication_token, :string,    limit: 255
    add_column :users, :auth_token_expiry,    :datetime

    AuthToken.where("auth_token_expiry > :time", time: Time.zone.now).
      each do |token|
        User.connection.exec_query(
          "UPDATE users SET authentication_token = $1, auth_token_expiry = $2 WHERE id=$3",
          "--Update Auth Token for #{token.user_id}--",
          [[nil, token.authentication_token], [nil, token.auth_token_expiry], [nil, token.user_id]]
        )
      end

    drop_table :auth_tokens
  end
end
