require_relative '../users'
require 'minitest/autorun'

class UsersTest < Minitest::Test

  def setup
    @inst = Users.new
    @user = '_throwaway-500'
    @user_home = "/home/#{@user}"
  end

  def teardown
    system "userdel -f #{@user} 2>/dev/null"
    system "rm -rf #{@user_home} 2>/dev/null"
  end

  def test_list_users
    require 'set'

    all_users = @inst.list_users
    assert_instance_of(Set, all_users)
    all_users.each do |u|
      assert_instance_of(String, u)
    end
  end

  def test_create_user
    before_users = @inst.list_users
    assert(!before_users.find { |u| u == @user })
    assert !Dir.exist?(@user_home)

    success = @inst.create_user(@user, 'mypassword')
    assert(success)
    assert Dir.exist?(@user_home)

    after_users = @inst.list_users
    diff = after_users - before_users
    assert_equal(@user, diff.first)
    assert_equal(1, diff.length) 
  end

  def test_remove_user
    @inst.create_user(@user, 'mypassword')
    assert Dir.exist?(@user_home)
    before_users = @inst.list_users
    assert(before_users.include?(@user))

    @inst.remove_user(@user)
    assert !Dir.exist?(@user_home)
    after_users = @inst.list_users
    assert(!after_users.include?(@user))

    diff = before_users - after_users
    assert_equal(@user, diff.first)
    assert_equal(1, diff.length) 
  end

  def test_create_duplicate_user
    @inst.create_user(@user, 'mypassword')

    ex = assert_raises(RuntimeError) { @inst.create_user(@user, "mypassword") }
    assert_equal('user already exists, aborting creation', ex.message)
  end

  def test_remove_invalid_user
    @inst.create_user(@user, 'mypassword')

    ex = assert_raises(RuntimeError) { @inst.remove_user("dinosaur") }
    assert_equal('user not found, aborting removal', ex.message)
  end

  def test_limit_username_to_regex
    invalid_names = ["will", "user", "HELLO", "MY_NAME_IS", "43242342", "_myname55", "_55-4543"]
    invalid_names.each do |i|
      ex = assert_raises(RuntimeError) { @inst.create_user(i, "password") }
      assert_equal('username does not fit allowable regex, aborting creation', ex.message)
    end
  end
end

