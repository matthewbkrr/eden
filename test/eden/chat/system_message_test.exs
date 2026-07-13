defmodule Eden.Chat.SystemMessageTest do
  use ExUnit.Case, async: true

  alias Eden.Accounts.User
  alias Eden.Chat.SystemMessage

  @user %User{id: 7, display_name: "Alice"}

  describe "constructors" do
    test "join_request/1 builds a pending knock meta" do
      assert SystemMessage.join_request(@user) == %{
               "action" => "join_request",
               "requester_id" => 7,
               "requester_name" => "Alice",
               "status" => "pending"
             }
    end

    test "member_added/1 and member_removed/2 build group-notice meta" do
      assert SystemMessage.member_added(@user) == %{
               "action" => "member_added",
               "user_id" => 7,
               "name" => "Alice"
             }

      assert SystemMessage.member_removed(7, "Alice") == %{
               "action" => "member_removed",
               "user_id" => 7,
               "name" => "Alice"
             }
    end

    test "resolve_status/2 sets a knock's status, keeping the rest of meta" do
      meta = SystemMessage.join_request(@user)
      assert SystemMessage.resolve_status(meta, "accepted")["status"] == "accepted"
      assert SystemMessage.resolve_status(meta, "declined")["requester_id"] == 7
    end

    test "resolve_status/2 rejects an unknown status" do
      assert_raise FunctionClauseError, fn -> SystemMessage.resolve_status(%{}, "bogus") end
    end
  end

  describe "describe/1" do
    test "decodes each system-message type into a tagged tuple" do
      assert {:join_request, %{requester_id: 7, requester_name: "Alice", status: "pending"}} =
               SystemMessage.describe(SystemMessage.join_request(@user))

      assert {:member_added, %{user_id: 7, name: "Alice"}} =
               SystemMessage.describe(SystemMessage.member_added(@user))

      assert {:member_removed, %{user_id: 7, name: "Alice"}} =
               SystemMessage.describe(SystemMessage.member_removed(7, "Alice"))
    end

    test "an unknown or empty action is :unknown (a future type never mis-decodes, #360/R189)" do
      assert SystemMessage.describe(%{"action" => "reminder"}) == :unknown
      assert SystemMessage.describe(%{}) == :unknown
    end
  end
end
