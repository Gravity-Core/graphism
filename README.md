# Graphism

An Elixir DSL that makes it faster & easier to build Absinthe powered GraphQL apis 
on top of Ecto and Postgres.

## Contributing

Please make sure your read and honour [our contributing guide](CONTRIBUTING.md).

## Getting started

### Configure mix

Install the `graphism.new` mix task:

```bash
$ wget https://github.com/pedro-gutierrez/graphism_new/raw/main/graphism_new-0.1.0.ez
$ mix archive.install ./graphism_new-0.1.0.ez
```

### Create your project

```bash
$ mix graphism.new blog
```

and run the following commands:

```bash
$ cd blog
$ mix deps.get
$ mix compile
$ mix graphism.migrations
$ mix ecto.create
$ mix ecto.migrate
```

### Run it

The generated projects contains a sample schema with a single `user` entity.

Start the project:

```bash
$ iex -S mix
```

Then visit [http://localhost:4001/graphiql](http://localhost:4001/graphiql) and start sending GraphQL requests:


```graphql
mutation {
  user{
    create(email: "john@farscape.com") {
      id,
      email
    }
  }
}
```

```graphql
query {
  users {
    all {
      id,
      email 
    }
  }
}
```

Don't forget to check the Documentation Explorer and discover all the queries and mutations that Graphism automatically generated for us.

### Next steps

From here, you might want to add new entities, attributes, unique keys, relations, custom actions etc.. to your schema.

For example, add the `:blog` and `:post` entities right after the existing `:user` entity:

```elixir
# lib/blog/schema.ex
defmodule Blog.Schema do
  use Graphism, repo: Blog.Repo

  ...

  entity :blog do
    unique(string(:name))
    belongs_to(:user, as: :owner)
    has_many(:posts)

    action(:read)
    action(:list)
    action(:create)
    action(:update)
    action(:delete)
  end

  entity :post do
    string(:title)
    text(:content)
    belongs_to(:blog)
    belongs_to(:user, as: :author, from: [:blog, :owner])

    action(:read)
    action(:list)
    action(:create)
    action(:update)
    action(:delete)
  end
end
```

Migrate your database: 

```bash
$ mix graphism.migrations
$ mix ecto.migrate
```

Start your project:

```bash
$ iex -S mix
```

Then refresh the GraphiQL UI, and start testing these brand new features that you just **didn't need to
code** (note: the uuids below will be different for you):

```graphql
mutation {
  blog {
    create(name: "John's blog", owner: "353e3684-8a55-482e-9bab-b91149db03bb") {
      id,
      name,
      owner {
        id,
        email
      }
    }
  }
}
```

```graphql
mutation {
  post {
    create(title: "Fetch the comfy chair", content: "It???s just like a VCR, except easier", blog: "b53a63c8-1400-4ca1-92eb-62cb3e73a782") {
      id,
      title,
      content,
      blog {
        id,
        name,
        owner {
          id,
          email
        }
      }
      author {
        id,
        email
      }
    }
  }
}
```

That is all for this guide!

Keep reading if you want to learn about all the features offered by Graphism...

## Schema Features

### Unique attributes

If you wish to ensure unicity, you can declare a field being `:unique`:

```elixir
entity :user do
  unique(string(:email))
  ...
end
```

Graphism will generate proper GraphQL queries for you, as well as indices in your database migrations.


### Optional attributes

Any standard attribute can be made optional:

```elixir
entity :post do
  optional(boolean(:draft))
  ...
end
```

Optional attributes will not be required in mutations.

### Default values

It is possible to defined default values for attributes that are optional. 

```elixir
entity :post do
  optional(boolean(:draft), default: true)
  ...
end
```

For convenience, the above can also be expressed as:

```elixir
entity :post do
  optional(boolean(:draft, default: true)
  ...
end
```

### Computed attributes

Computed attributes are part of your schema, they are stored, and can also be queried.

However, since they are computed, they won't be included in your mutations, therefore it is not possible to modify their values explicitly.

```elixir
entity :post do
  computed(boolean(:draft, default: true)
  ...
end
```

### Self referencing entities

Sometimes it is useful to have schemas where an entity needs to reference itself, eg when building a tree-like structure:

```elixir
entity :node do
  maybe(belongs_to(:node, as: :parent))
  ...
end
```

### Sorting results

It is possible to customize the default ordering of results when doing list queries:

```elixir
entity :post, sort: [desc: :inserted_at] do
...
end 
```

The `:sort` options can take the following values:

* `:none`, meaning no default ordering should be applied.
* an Ecto compatible keyword list expression, eg `[desc: :inserted_at]`

If not specified, then `[asc: :inserted_at]` will be used by default.

### Immutable fields

Attributes or relations can be made immutable. This means once they are initialized, they cannot be modified:

```elixir
entity :file do
  ...
  immutable(upload(:content))
  ...
end
```

### Non empty fields

Sometimes we need fields that are optional at the api level, while ensuring non empty values are stored in the database:

```elixir
entity :file do
  ...
  optional(non_empty(string(:name))
  ...
end
```

### Standard actions

Graphism provides with five basic standard actions:

* `read`
* `list`
* `create`
* `update`
* `delete`

### User defined actions

On top of the standard actions, it is possible to defined custom actions:

```elixir
entity :post do
  ...
  action(:publish, using: MyBlog.Post.Publish, desc: "Publish a post") 
  ...
end
```

It is also possible to further customize inputs (`args`) and outputs (`:produces`) in custom actions:

```elixir
entity :post do
  ...
  action(:publish, using: MyBlog.Post.Publish, args: [:id], :produces: :post) 
  ...
end
```

It is essential to provide the implementation for your custom action as a simple `:using` Graphism hook.

### Aggregate queries

In addition to listing entities, it is also possible to aggregate (eg. count) them. 

```
query {
  contacts {
    aggregateAll {
      count
    }
  }
}
```

These will be generated by Graphism for you. 


### User defined lists

Sometimes the default lists added by Graphism might not suit you and it is possible that you need to
define your own queries:

```elixir
entity :post do
  list(:my_custom_query, args: [...], using: MyBlog.Post.MyCustomQuery)
end
```

All you need need to do is return an ok tuple with the query to execute. 

Graphism will automatically add support for sorting and pagination for you. In addition, Graphism will also generate
custom aggregations so that you can also run:

```
query {
  posts {
    aggregateMyCustomQuery(...) {
      count 
    }
  }
}
```

### Lookup arguments

Let's say you want to create an invite for a user. Here is a basic schema:

```elixir
entity :user do
  unique(string(:email))
  ...
end

entity :invite do
  belongs_to(:user)
  action(:create)
  ...
end
```

With this, your create invite mutation will receive the ID of an existing user. But in practice,
sometimes it might happen that you don't know that user's id, just their email.

In that case, you can tell Graphism to lookup the user by their email for you:

```elixir
entity :invite do
  ...
  action(:create, lookup: [user: :email])
  ...
end
```

Graphism will however complain if the lookup you are defining is not based on a unique key.

### Client generated ids

Sometimes it makes more sense to let the client specify their own ids:

```elixir
entity :item, modifiers: [:client_ids] do
  ...
  action(:create)
  ...
end
```

This will stop Graphism from generating ids for you. However you will still need to pass in a valid
UUID v4 string.

### Composite keys

By default, Graphism uses UUIDs as primary keys, and, as you've already seen, it is also possible to define
unique keys, such as a name, or an email, using the `unique(string(:name))` or `unique(string(:email))` notation.

But sometimes unique keys are made of more than just one field:

```elixir
entity :user do
  unique(string(:name))
end
      
entity :organisation do 
  unique(string(:name))
end

entity :membership do
  belongs_to(:user)
  belongs_to(:organisation)
  key([:user, :organisation]) # <-- composite key
  action(:read)
end
```

In the above example, we are saying that a user can belong to an organisation only once. Graphism will take
care of creating the right indices and GraphQL queries for you.

### Non unique keys

Composite keys can be turned into indices by setting `unique: false`.

In this case, Graphism will automatically generate list and aggregate queries for you.

### Hooks

Hooks are a mechanism in Graphism for customization. They are implemented as standard OTP behaviours.

Graphism supports the following types of hooks:

* `Graphism.Hooks.Simple` are suitable as `:using` hooks in custom actions.
* `Graphism.Hooks.Update` are suitable as `:before` hooks on standard `:update` actions. 
* `Graphism.Hooks.Allow` are suitable as `:allow` hooks in both standard or custom actions.

Please see the module documentations for further details.

### Absinthe middleware

Custom Absinthe middlewares can be also be plugged:

```elixir
use Graphism, repo: ..., middleware: [My.Middleware]
```

### Skippable migrations

Sometimes we need to write our own custom migrations. It is possible to tell Graphism to ignore these
by setting the `@graphism` module attribute:

```elixir
defmodule My.Custom.Migration do
  use Ecto.Migration

  @graphism [:skip] # add the :skip option

  def up do
    execute("...")
  end
end
```

### Pagination and sorting

Graphism will build all your queries with optional sorting and pagination. 

Based on this simple entity:

```elixir
entity :contact do
  string(:first_name)
  string(:last_name)
  action(:list)
end
```

You can query all your contacts by chunks:

```
query {
  contacts {
    all(sortBy: "lastName", sortDirection: ASC, limit: 20, offset: 40) {
      firstName,
      lastName
    }
  }
}
```



### Cascade deletes

By default, it is not possible to delete an entity if it has children entities pointing to it. But this can be
overriden on a per-relation basis:

```elixir
entity :node do
  ...
  belongs_to(:node, as: parent, delete: :cascade)
  ...
end
```

Graphism will take of writing the correct migrations, including dropping existing constraints, in order to fully support
changes in this policy.

### Schema introspection

Sometimes you might need to be able to instrospect your schema in a programmatic way. Graphism generates
for you a couple of useful functions:

* `field_spec/1`
* `field_specs/1`

Examples:

```elixir
iex> MyBlog.Schema.Post.field_spec("body")
{:ok, :string, :body}

iex> MyBlog.Schema.Post.field_spec("comments")
{:ok, :has_many, :comment, MyBlog.Schema.Comment}

iex> MyBlog.Schema.Comment.field_spec("blog")
{:ok, :belongs_to, :blog, MyBlog.Schema.Post, :blog_id}

iex> MyBlog.Schema.Comment.field_specs({:belongs_to, MyBlog.Schema.Post})
[{:belongs_to, :blog, MyBlog.Schema.Post, :blog_id}]
```

### Json types

Graphism allows you to define attributes of `json` type in order to store unstructured data as maps or arrays:

```elixir
entity :color do
  json(:data)
  action(:create)
  action(:list)
end
```

With this, you can define the `data` as a string value in your mutation:

```graphql
mutation {
  color{
    create(data: "{ \"r\": 255, \"g\": 0, \"b\": 0 }") {
     id,
     data 
    }
  }
}
```

And you will get the data back as json:

```json
{
  "data": {
    "color": {
      "create": {
        "id": "eb40ddfb-2208-4588-b57f-0931fa18c0fe",
        "data": {
          "b": 0,
          "g": 0,
          "r": 255
        }
      }
    }
  }
}
```

### Telemetry

Graphism emits telemetry events for various operations and publishes their duration:

| event | measurement | metadata |
| --- | --- | --- |
| `[:graphism, :allow, :stop]` | `:duration` | `:entity`, `:kind`, `:value` |
| `[:graphism, :scope, :stop]` | `:duration` | `:entity`, `:kind`, `:value` |
| `[:graphism, :relation, :stop]` | `:duration` | `:entity`, `:relation` |

You can also subscribe to the `[:start]` and `[:exception]` events, since Graphism relies on `:telemetry.span/3`.
