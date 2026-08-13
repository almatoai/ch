defmodule Ch.VariantTest do
  use ExUnit.Case, parameterize: [%{query_options: []}, %{query_options: [multipart: true]}]
  import Ch.Test, only: [parameterize_query!: 2, parameterize_query!: 4]

  # https://clickhouse.com/docs/sql-reference/data-types/variant

  @moduletag :variant

  setup do
    conn = start_supervised!({Ch, database: Ch.Test.database()})
    {:ok, conn: conn}
  end

  test "basic", ctx do
    assert parameterize_query!(ctx, "select null::Variant(UInt64, String, Array(UInt64))").rows ==
             [[nil]]

    assert parameterize_query!(ctx, "select [1]::Variant(UInt64, String, Array(UInt64))").rows ==
             [[[1]]]

    assert parameterize_query!(ctx, "select 0::Variant(UInt64, String, Array(UInt64))").rows == [
             [0]
           ]

    assert parameterize_query!(
             ctx,
             "select 'Hello, World!'::Variant(UInt64, String, Array(UInt64))"
           ).rows ==
             [["Hello, World!"]]
  end

  # https://github.com/plausible/ch/issues/272
  test "ordering internal types", ctx do
    test = %{
      "'hello'" => "hello",
      "-10" => -10,
      "true" => true,
      "map('hello', null::Nullable(String))" => %{"hello" => nil},
      "map('hello', 'world'::Nullable(String))" => %{"hello" => "world"}
    }

    for {value, expected} <- test do
      assert parameterize_query!(
               ctx,
               "select #{value}::Variant(String, Int32, Bool, Map(String, Nullable(String)))"
             ).rows == [[expected]]
    end
  end

  test "with a table", ctx do
    # https://clickhouse.com/docs/sql-reference/data-types/variant#creating-variant
    parameterize_query!(ctx, """
    CREATE TABLE variant_test (v Variant(UInt64, String, Array(UInt64))) ENGINE = Memory;
    """)

    on_exit(fn -> Ch.Test.query("DROP TABLE variant_test") end)

    parameterize_query!(
      ctx,
      "INSERT INTO variant_test VALUES (NULL), (42), ('Hello, World!'), ([1, 2, 3]);"
    )

    assert parameterize_query!(ctx, "SELECT v FROM variant_test").rows == [
             [nil],
             [42],
             ["Hello, World!"],
             [[1, 2, 3]]
           ]

    # https://clickhouse.com/docs/sql-reference/data-types/variant#reading-variant-nested-types-as-subcolumns
    assert parameterize_query!(
             ctx,
             "SELECT v, v.String, v.UInt64, v.`Array(UInt64)` FROM variant_test;"
           ).rows ==
             [
               [nil, nil, nil, []],
               [42, nil, 42, []],
               ["Hello, World!", "Hello, World!", nil, []],
               [[1, 2, 3], nil, nil, [1, 2, 3]]
             ]

    assert parameterize_query!(
             ctx,
             "SELECT v, variantElement(v, 'String'), variantElement(v, 'UInt64'), variantElement(v, 'Array(UInt64)') FROM variant_test;"
           ).rows == [
             [nil, nil, nil, []],
             [42, nil, 42, []],
             ["Hello, World!", "Hello, World!", nil, []],
             [[1, 2, 3], nil, nil, [1, 2, 3]]
           ]
  end

  test "rowbinary picks the member matching the value, not the first that fits", ctx do
    # ClickHouse orders variant members by type name, so the discriminator order here is
    # Bool, Float64, Int64, String — encoding an integer with the first member that *accepts* it
    # would store every integer as a Float64.
    type = "Variant(Bool, Float64, Int64, String)"

    parameterize_query!(ctx, "CREATE TABLE variant_member_test (v #{type}) ENGINE = Memory;")
    on_exit(fn -> Ch.Test.query("DROP TABLE variant_member_test") end)

    parameterize_query!(
      ctx,
      "INSERT INTO variant_member_test FORMAT RowBinary",
      [[nil], [true], [false], [42], [-7], [4.2], ["hello"], ["42"]],
      types: [type]
    )

    assert parameterize_query!(ctx, "SELECT variantType(v), v FROM variant_member_test").rows == [
             ["None", nil],
             ["Bool", true],
             ["Bool", false],
             ["Int64", 42],
             ["Int64", -7],
             ["Float64", 4.2],
             ["String", "hello"],
             ["String", "42"]
           ]
  end

  test "rowbinary keeps Enum and Decimal members from losing to String", ctx do
    type = "Variant(Decimal(9, 2), Enum8('a' = 1, 'b' = 2), String)"

    # ClickHouse itself considers an Enum and a String member ambiguous, which is exactly why the
    # member has to be picked from the value rather than from whichever encoder accepts it first.
    suspicious = [settings: [allow_suspicious_variant_types: 1]]

    parameterize_query!(
      ctx,
      "CREATE TABLE variant_enum_test (v #{type}) ENGINE = Memory;",
      [],
      suspicious
    )

    on_exit(fn -> Ch.Test.query("DROP TABLE variant_enum_test") end)

    parameterize_query!(
      ctx,
      "INSERT INTO variant_enum_test FORMAT RowBinary",
      [[Decimal.new("1.50")], ["a"], ["b"], ["c"], [nil]],
      [types: [type]] ++ suspicious
    )

    # variantType/1 returns an Enum8 whose labels here contain escaped quotes, which Ch.Types
    # can't parse yet, so compare the type name as a String
    assert parameterize_query!(
             ctx,
             "SELECT variantType(v)::String, v FROM variant_enum_test"
           ).rows ==
             [
               ["Decimal(9, 2)", Decimal.new("1.50")],
               ["Enum8('a' = 1, 'b' = 2)", "a"],
               ["Enum8('a' = 1, 'b' = 2)", "b"],
               # not one of the labels, so it belongs in the String member
               ["String", "c"],
               ["None", nil]
             ]
  end

  test "rowbinary with a JSON member", ctx do
    # ClickHouse's JSON type only accepts objects at the top level, so a list round-trips through
    # the String member as JSON text.
    type = "Variant(Bool, Float64, Int64, JSON(max_dynamic_paths=64), String)"

    parameterize_query!(ctx, "CREATE TABLE variant_json_test (v #{type}) ENGINE = Memory;")
    on_exit(fn -> Ch.Test.query("DROP TABLE variant_json_test") end)

    parameterize_query!(
      ctx,
      "INSERT INTO variant_json_test FORMAT RowBinary",
      [[%{"k" => 1}], [%{}], [7], ["plain"], [nil]],
      types: [type]
    )

    assert parameterize_query!(ctx, "SELECT variantType(v), v FROM variant_json_test").rows == [
             ["JSON(max_dynamic_paths=64)", %{"k" => 1}],
             ["JSON(max_dynamic_paths=64)", %{}],
             ["Int64", 7],
             ["String", "plain"],
             ["None", nil]
           ]
  end

  test "rowbinary with a JSON member carrying a type hint and SKIP", ctx do
    # the JSON parameters are carried as text rather than parsed, so a hinted path and a SKIP
    # directive work as members just like max_dynamic_paths does
    type = "Variant(JSON(a UInt32, SKIP skipped, SKIP REGEXP '^tmp'), String)"

    parameterize_query!(ctx, "CREATE TABLE variant_json_hint_test (v #{type}) ENGINE = Memory;")
    on_exit(fn -> Ch.Test.query("DROP TABLE variant_json_hint_test") end)

    parameterize_query!(
      ctx,
      "INSERT INTO variant_json_hint_test FORMAT RowBinary",
      [[%{"a" => 1}], [%{"a" => 2, "skipped" => "gone", "tmp_x" => "gone"}], ["plain"], [nil]],
      types: [type]
    )

    json = "JSON(a UInt32, SKIP skipped, SKIP REGEXP '^tmp')"

    assert parameterize_query!(
             ctx,
             "SELECT variantType(v)::String, v FROM variant_json_hint_test"
           ).rows == [
             [json, %{"a" => 1}],
             # the named SKIP path really is dropped by the server
             [json, %{"a" => 2, "tmp_x" => "gone"}],
             ["String", "plain"],
             ["None", nil]
           ]
  end

  test "rowbinary", ctx do
    parameterize_query!(ctx, """
    CREATE TABLE variant_test (v Variant(UInt64, String, Array(UInt64))) ENGINE = Memory;
    """)

    on_exit(fn -> Ch.Test.query("DROP TABLE variant_test") end)

    parameterize_query!(
      ctx,
      "INSERT INTO variant_test FORMAT RowBinary",
      [[nil], [42], ["Hello, World!"], [[1, 2, 3]]],
      types: ["Variant(UInt64, String, Array(UInt64))"]
    )

    assert parameterize_query!(ctx, "SELECT v FROM variant_test").rows == [
             [nil],
             [42],
             ["Hello, World!"],
             [[1, 2, 3]]
           ]
  end
end
