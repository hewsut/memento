defmodule Memento.Query do
  require Memento.Mnesia
  require Memento.Error

  alias Memento.Query
  alias Memento.Table
  alias Memento.Mnesia


  @moduledoc """
  Module to read/write from Memento Tables.

  This module provides the most important transactional operations
  that can be executed on Memento Tables. Mnesia's "dirty" methods
  are left out on purpose. In almost all circumstances, these
  methods would be enough for interacting with Memento Tables, but
  for very special situations, it is better to directly use the
  API provided by the Erlang `:mnesia` module.


  TODO: mention non-nil keys

  ## Transaction Only

  All the methods exported by this module can only be executed
  within the context of a `Memento.Transaction`. Outside the
  transaction (synchronous or not), these methods will raise an
  error, even though they are ignored in all other examples.

  ```
  # Will raise an error
  Memento.Query.read(Blog.Post, :some_id)

  # Will work fine
  Memento.transaction fn ->
    Memento.Query.read(Blog.Post, :some_id)
  end
  ```


  ## Basic Queries

  ```
  read
  first
  write
  all
  ```


  ## Advanced Queries and MatchSpec

  Special cases here are the `match/3` and `select/3` methods,
  which use a superset of Erlang's
  [`match_spec`](http://erlang.org/doc/apps/erts/match_spec.html)
  to make working with them much easier.
  """





  # Type Definitions
  # ----------------


  @typedoc """
  Option Keyword that can be passed to some methods.

  These are all the possible options that can be set in the given
  keyword list, although it mostly depends on the method which
  options it actually uses.

  ## Options

  - `lock`: What kind of lock to acquire on the item in that
  transaction. This is the most common option, that almost all
  methods accept, and usually has some default value depending on
  the method. See `t:lock/0` for more details.

  - `limit`: The maximum number of items to return in a query.
  This is used only read queries like `match/3` or `select/3`, and
  is of the type `t:non_neg_integer/0`. Defaults to `nil`, resulting
  in no limit and returning all records.

  - `coerce`: Records in Mnesia are stored in the form of a `tuple`.
  This converts them into simple Memento struct records of type
  `t:Memento.Table.record/0`. This is equivalent to calling
  `Query.Data.load/1` on the returned records. This option is only
  available to some read methods like `select/3` & `match/3`, and its
  value defaults to `true`.
  """
  @type options :: [
    lock: lock,
    limit: non_neg_integer,
    coerce: boolean,
  ]



  @typedoc """
  Types of locks that can be acquired.

  There are, in total, 3 types of locks that can be aqcuired, but
  some operations don't support all of them. The `write/2` method,
  for example, can only accept `:write` or `:sticky_write` locks.

  Conflicting lock requests are automatically queued if there is
  no risk of deadlock. Otherwise, the transaction must be
  terminated and executed again. Memento does this automatically
  as long as the upper limit of `retries` is not reached in a
  transaction.


  ## Types

  - `:write` locks are exclusive. That means, if one transaction
  acquires a write lock, no other transaction can acquire any
  kind of lock on the same item.

  - `:read` locks can be shared, meaning if one transaction has a
  read lock on an item, other transactions can also acquire a
  read lock on the same item. However, no one else can acquire a
  write lock on that item while the read lock is in effect.

  - `:sticky_write` locks are used for optimizing write lock
  acquisitions, by informing other nodes which node is locked. New
  sticky lock requests from the same node are performed as local
  operations.


  For more details, see `:mnesia.lock/2`.
  """
  @type lock :: :read | :write | :sticky_write





  # Public API
  # ----------


  @doc """
  Finds the Memento record for the given id in the specified table.

  If no record is found, `nil` is returned. You can also pass an
  optional keyword list as the 3rd argument. The only option currently
  supported is `:lock`, which acquires a lock of specified type on the
  operation (defaults to `:read`). See `t:lock/0` for more details.

  This method works a bit differently from the original `:mnesia.read/3`
  when the table type is `:bag`. Since a bag can have many records
  with the same key, this returns only the first one. If you want to
  fetch all records with the given key, use `match/3` or `select/2`.


  ## Example

  ```
  Memento.Query.read(Blog.Post, 1)
  # => %Blog.Post{id: 1, ... }

  Memento.Query.read(Blog.Post, 2, lock: :write)
  # => %Blog.Post{id: 2, ... }

  Memento.Query.read(Blog.Post, :unknown_id)
  # => nil
  ```
  """
  @spec read(Table.name, any, options) :: Table.record | nil
  def read(table, id, opts \\ []) do
    lock = Keyword.get(opts, :lock, :read)
    case Mnesia.call(:read, [table, id, lock]) do
      []           -> nil
      [record | _] -> Query.Data.load(record)
    end
  end




  @doc """
  Writes a Memento record to its Mnesia table.

  Returns `:ok` on success, or aborts the transaction on failure.
  This operatiion acquires a lock of the kind specified, which can
  be either `:write` or `:sticky_write` (defaults to `:write`).
  See `t:lock/0` and `:mnesia.write/3` for more details.

  The `key` is the important part. For now, this method does not
  automatically generate new `keys`, so this has to be done on the
  client side.

  TODO: Implement some sort of `autogenerate` for write.

  ## Examples

  ```
  Memento.Query.write(%Blog.Post{id: 4, title: "something", ... })
  # => :ok

  Memento.Query.write(%Blog.Author{username: "sye", ... })
  # => :ok
  ```
  """
  @spec write(Table.record, options) :: :ok
  def write(record = %{__struct__: table}, opts \\ []) do
    record = Query.Data.dump(record)
    lock   = Keyword.get(opts, :lock, :write)

    Mnesia.call(:write, [table, record, lock])
  end




  @doc """
  Returns all records of a Table.

  This is equivalent to calling `match/3` with the catch-all pattern.
  This also accepts an optional `lock` option to acquire that kind of
  lock in the transaction (defaults to `:read`). See `t:lock/0` for
  more details about lock types.

  ```
  # Both are equivalent
  Memento.Query.all(Movie)
  Memento.Query.match(Movie, {:_, :_, :_, :_})
  ```
  """
  @spec all(Table.name, options) :: list(Table.record)
  def all(table, opts \\ []) do
    pattern = table.__info__.query_base
    lock = Keyword.get(opts, :lock, :read)

    :match_object
    |> Mnesia.call([table, pattern, lock])
    |> coerce_records
  end




  @doc """
  Returns all records in a table that match the specified pattern.

  This method takes the name of a `Memento.Table` and a tuple pattern
  representing the values of those attributes, and returns all
  records that match it. It uses `:_` to represent attributes that
  should be ignored. The tuple passed should be of the same length as
  the number of attributes in that table, otherwise it will throw an
  exception.

  It's recommended to use the `select/3` method as it is more
  user-friendly, can let you make complex selections.

  Also accepts an optional argument `:lock` to acquire the kind of
  lock specified in that transaction (defaults to `:read`). See
  `t:lock/0` for more details. Also see `:mnesia.match_object/3`.

  ## Examples

  Suppose a `Movie` Table with these attributes: `id`, `title`, `year`,
  and `director`. So the tuple passed in the match query should have
  4 elements.

  ```
  # Get all movies from the Table
  Memento.Query.match(Movie, {:_, :_, :_, :_})

  # Get all movies named 'Rush', with a write lock on the item
  Memento.Query.match(Movie, {:_, "Rush", :_, :_}, lock: :write)

  # Get all movies directed by Tarantino
  Memento.Query.match(Movie, {:_, :_, :_, "Quentin Tarantino"})

  # Get all movies directed by Spielberg, in the year 1993
  Memento.Query.match(Movie, {:_, :_, 1993, "Steven Spielberg"})

  # Will raise exceptions
  Memento.Query.match(Movie, {:_, :_})
  Memento.Query.match(Movie, {:_, :_, :_})
  Memento.Query.match(Movie, {:_, :_, :_, :_, :_})
  ```
  """
  @spec match(Table.name, tuple, options) :: list(Table.record) | no_return
  def match(table, pattern, opts \\ []) when is_tuple(pattern) do
    validate_match_pattern!(table, pattern)
    lock = Keyword.get(opts, :lock, :read)

    # Convert {x, y, z} -> {Table, x, y, z}
    pattern =
      Tuple.insert_at(pattern, 0, table)

    :match_object
    |> Mnesia.call([table, pattern, lock])
    |> coerce_records
  end




  @doc """
  Returns all records in the given table according to the full Erlang
  `match_spec`.

  This method accepts a pure Erlang `match_spec` term as described below,
  which can be used to write some very complex queries, but that also
  makes it very hard to use for beginners, and overly complex for everyday
  queries. It is highly recommended that you use the `select/3` method
  which makes it much easier to write complex queries that work just as
  well in 99% of the cases, by making some assumptions.

  The arguments are directly passed on to the `:mnesia.select/4` method
  without translating queries, as they are done in `select/3`.


  ## Options

  See `t:options/0` for details about these options:

  - `lock` (defaults to `:read`)
  - `limit` (defaults to `nil`, meaning return all)
  - `coerce` (defaults to `true`)


  ## Match Spec

  An Erlang "Match Specification" or `match_spec` is a term describing
  a small program that tries to match something. This is most popularly
  used in both `:ets` and `:mnesia`. Quite simply, the grammar can be
  defined as:

  - `match_spec` = `[match_function, ...]` (List of match functions)
  - `match_function` = `{match_head, [guard, ...], [result]}`
  - `match_head` = `tuple` (A tuple representing attributes to match)
  - `guard` = A tuple representing conditions for selection
  - `result` = Atom describing the fields to return as the result

  Here, the `match_head` describes the attributes to match (like in
  `match/3`. You can use literals to specify an exact value to be
  matched against or `:"$n"` variables (`:$1`, `:$2`, ...)  that can be
  used so they can be referenced in the guards. You can get a default
  value by calling `YourTable.__info__().query_base`.

  The second element in the tuple is a list of `guard` terms, where each
  guard is basically a tuple representing a condition of the form
  `{operation, arg1, arg2}` which can be simple `{:==, :"$2", literal}`
  tuples or nested values like `{:andalso, guard1, guard2}`. Finally,
  `result` represents the fields to return. Use `:"$_"` to return all
  fields, `:"$n"` to return a specific field or `:"$$"` for all fields
  specified as variables in the `match_head`.


  ## Examples

  Suppose a `Movie` Table with these attributes: `id`, `title`, `year`,
  and `director`. So the tuple passed in the match query should have
  4 elements.

  Return all records:

  ```
  match_head = Movie.__info__.query_base
  result = [:"$_"]
  guards = []

  Memento.Query.select_raw(Movie, [{match_head, guards, result}])
  # => [%Movie{...}, ...]
  ```

  Get all movies with the title "Rush":

  ```
  # We're using the match_head pattern here, but you can also use guards
  match_head = {Movie, :"$1", "Rush", :"$2", :"$3"}
  result = [:"$_"]
  guards = []

  Memento.Query.select_raw(Movie, [{match_head, guards, result}])
  # => [%Movie{title: "Rush", ...}, ...]
  ```

  Get all movies title names, that were directed by Tarantino before the year 2000:

  ```
  # Using guards only here, but you can mix and match with head.
  # You can also use a nested `{:andalso, guard1, guard2}` tuple
  # here instead.
  #
  # We used the result value `[:"$2"]` so it only returns the
  # second (i.e. title) field. Because of this, we're also not
  # coercing the results.

  match_head = {Movie, :"$1", :"$2", :"$3", :"$4"}
  result = [:"$2"]
  guards = [{:<, :"$3", 2000}, {:==, :"$4", "Quentin Tarantino"}]

  Memento.Query.select_raw(Movie, [{match_head, guards, result}], coerce: false)
  # => ["Reservoir Dogs", "Pulp Fiction", ...]
  ```

  Get all movies directed by Tarantino or Spielberg, after the year 2010:

  ```
  match_head = {Movie, :"$1", :"$2", :"$3", :"$4"}
  result = [:"$_"]
  guards = [
    {:andalso,
      {:>, :"$3", 2010},
      {:orelse,
        {:==, :"$4", "Quentin Tarantino"},
        {:==, :"$4", "Steven Spielberg"},
      }
    }
  ]

  Memento.Query.select_raw(Movie, [{match_head, guards, result}], coerce: true)
  # => [%Movie{...}, ...]
  ```

  ## Notes

  - It's important to note that for customized results (not equal to
  `:"$_"`), you should specify `coerce: false`, so it doesn't raise errors.

  - Unlike the `select/3` method, the `operation` values the `guard` tuples
  take in this method are Erlang atoms, not Elixir ones. For example,
  instead of `:and` & `:or`, they will be `:andalso` & `:orelse`. Similarly,
  you will have to use `:"/="` instead of `:!=` and `:"=<"` instead of `:<=`.

  See the [`Match Specification`](http://erlang.org/doc/apps/erts/match_spec.html)
  docs, `:mnesia.select/2` and `:ets.select/2` more details and examples.
  """
  @spec select_raw(Table.name, term, options) :: list(Table.record | tuple)
  def select_raw(table, match_spec, opts \\ []) do
    # Default options
    lock   = Keyword.get(opts, :lock, :read)
    limit  = Keyword.get(opts, :limit, nil)
    coerce = Keyword.get(opts, :coerce, true)

    # Use select/4 if there is limit, otherwise use select/3
    args =
      case limit do
        nil   -> [table, match_spec, lock]
        limit -> [table, match_spec, limit, lock]
      end

    # Execute select method with the no. of args
    result = Mnesia.call(:select, args)

    # Coerce result conversion if `coerce: true`
    case coerce do
      true  -> coerce_records(result)
      false -> result
    end
  end

  # # Result is automatically formatted
  # def where(table, pattern, lock: :read, limit: nil, coerce: true)

  # # Result is not casted
  # def select(table, match_spec, lock: :read, limit: nil, coerce: false)

  # def test_matchspec





  # Private Helpers
  # ---------------


  # Coerce results when is simple list
  defp coerce_records(records) when is_list(records) do
    Enum.map(records, &Query.Data.load/1)
  end

  # Coerce results when is tuple
  defp coerce_records({records, _term}) when is_list(records) do
    # TODO: Use this {coerce_records(records), term}
    coerce_records(records)
  end


  # Raises error if tuple size and no. of attributes is not equal
  defp validate_match_pattern!(table, pattern) do
    same_size? =
      (tuple_size(pattern) == table.__info__.size)

    unless same_size? do
      Memento.Error.raise(
        "Match Pattern length is not equal to the no. of attributes"
      )
    end
  end

end
