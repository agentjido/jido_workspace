defmodule Jido.Shell.Backend.SSHKeyCallbackTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Backend.SSH.KeyCallback

  test "host key callback always accepts" do
    assert KeyCallback.is_host_key(:key, ~c"host", 22, :"ssh-rsa", []) == true
  end

  test "accepts RSA keys for legacy and SHA2 RSA algorithms" do
    pem = rsa_private_key_pem()

    assert_rsa_key(KeyCallback.user_key(:"ssh-rsa", key: pem))
    assert_rsa_key(KeyCallback.user_key(:"rsa-sha2-256", key: pem))
    assert_rsa_key(KeyCallback.user_key(:"rsa-sha2-512", key: pem))
    assert_rsa_key(KeyCallback.user_key(:"ssh-rsa", key_cb_private: [key: pem]))
  end

  test "accepts ECDSA algorithms for EC keys" do
    pem = ecdsa_private_key_pem()

    assert_ec_key(KeyCallback.user_key(:"ecdsa-sha2-nistp256", key: pem))
    assert_ec_key(KeyCallback.user_key(:"ecdsa-sha2-nistp384", key: pem))
    assert_ec_key(KeyCallback.user_key(:"ecdsa-sha2-nistp521", key: pem))
  end

  test "decodes OpenSSH ed25519 keys and rejects mismatched algorithms" do
    pem = openssh_ed25519_key()

    assert {:ok, {:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 112}}, _, _}} =
             KeyCallback.user_key(:"ssh-ed25519", key: pem)

    assert {:error, :key_decode_failed} =
             KeyCallback.user_key(:"ssh-ed448", key: pem)

    assert {:error, :key_decode_failed} =
             KeyCallback.user_key(:"ssh-rsa", key: pem)
  end

  test "returns expected errors for missing, unmatched, and malformed keys" do
    rsa_pem = rsa_private_key_pem()

    assert {:error, :no_key_provided} = KeyCallback.user_key(:"ssh-rsa", [])
    assert {:error, :no_key_provided} = KeyCallback.user_key(:"ssh-rsa", key_cb_private: [])

    assert {:error, :no_matching_key} = KeyCallback.user_key(:"ssh-ed25519", key: rsa_pem)

    assert {:error, :no_keys_found} =
             KeyCallback.user_key(:"ssh-rsa", key: "not-a-key")

    undecodable_pem = :public_key.pem_encode([{:RSAPrivateKey, <<1, 2, 3, 4>>, :not_encrypted}])
    assert {:error, :key_decode_failed} = KeyCallback.user_key(:"ssh-rsa", key: undecodable_pem)
  end

  defp assert_rsa_key({:ok, key}) when is_tuple(key) do
    assert elem(key, 0) == :RSAPrivateKey
  end

  defp assert_ec_key({:ok, key}) when is_tuple(key) do
    assert elem(key, 0) == :ECPrivateKey
  end

  defp openssh_ed25519_key do
    {:ECPrivateKey, version, private, curve, public, attributes} =
      :public_key.generate_key({:namedCurve, {1, 3, 101, 112}})

    # OpenSSH stores the public key after the private seed.
    key = {:ECPrivateKey, version, private <> public, curve, public, attributes}
    :ssh_file.encode([{[{key, "test"}], []}], :openssh_key_v1)
  end

  defp rsa_private_key_pem do
    key = :public_key.generate_key({:rsa, 1_024, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  defp ecdsa_private_key_pem do
    key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end
end
