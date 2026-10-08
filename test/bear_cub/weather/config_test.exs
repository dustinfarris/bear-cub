defmodule BearCub.Weather.ConfigTest do
  use ExUnit.Case, async: true

  alias BearCub.Weather.Config

  # Distinctive fake coordinates: household data never enters git.
  @lat "12.3456"
  @lng "-65.4321"

  describe "from_env/1" do
    test "defaults the thresholds and leaves the location unset" do
      assert Config.from_env(%{}) == [
               latitude: nil,
               longitude: nil,
               hot_at: 80,
               cold_below: 60,
               precip_chance_at: 40
             ]
    end

    test "parses every value from its env var" do
      env = %{
        "BEAR_CUB_WEATHER_LATITUDE" => @lat,
        "BEAR_CUB_WEATHER_LONGITUDE" => @lng,
        "BEAR_CUB_WEATHER_HOT_AT" => "85",
        "BEAR_CUB_WEATHER_COLD_BELOW" => "55.5",
        "BEAR_CUB_WEATHER_PRECIP_CHANCE_AT" => "25"
      }

      assert Config.from_env(env) == [
               latitude: 12.3456,
               longitude: -65.4321,
               hot_at: 85,
               cold_below: 55.5,
               precip_chance_at: 25
             ]
    end

    test "a lone coordinate parses; turning weather off is the consumer's call" do
      config = Config.from_env(%{"BEAR_CUB_WEATHER_LATITUDE" => @lat})
      assert config[:latitude] == 12.3456
      assert config[:longitude] == nil
    end

    test "raises when cold_below exceeds hot_at" do
      env = %{"BEAR_CUB_WEATHER_HOT_AT" => "70", "BEAR_CUB_WEATHER_COLD_BELOW" => "71"}
      assert_raise ArgumentError, ~r/cold_below/, fn -> Config.from_env(env) end
    end

    test "cold_below equal to hot_at is allowed" do
      env = %{"BEAR_CUB_WEATHER_HOT_AT" => "70", "BEAR_CUB_WEATHER_COLD_BELOW" => "70"}
      assert Config.from_env(env)[:hot_at] == 70
    end

    test "raises when the chance is outside 0-100" do
      for bad <- ["-1", "101"] do
        env = %{"BEAR_CUB_WEATHER_PRECIP_CHANCE_AT" => bad}
        assert_raise ArgumentError, ~r/precip_chance_at/, fn -> Config.from_env(env) end
      end
    end

    test "accepts the chance bounds 0 and 100" do
      for ok <- ["0", "100"] do
        env = %{"BEAR_CUB_WEATHER_PRECIP_CHANCE_AT" => ok}
        assert Config.from_env(env)[:precip_chance_at] == String.to_integer(ok)
      end
    end

    test "raises on a non-numeric value without echoing the location" do
      error =
        assert_raise ArgumentError, fn ->
          Config.from_env(%{"BEAR_CUB_WEATHER_HOT_AT" => "warm"})
        end

      assert error.message =~ "BEAR_CUB_WEATHER_HOT_AT"

      error =
        assert_raise ArgumentError, fn ->
          Config.from_env(%{"BEAR_CUB_WEATHER_LATITUDE" => "12.3456N"})
        end

      assert error.message =~ "BEAR_CUB_WEATHER_LATITUDE"
      refute error.message =~ "12.3456"
    end
  end
end
