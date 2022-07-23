defmodule Graphism.Rest do
  @moduledoc "Generates a REST api"

  alias Graphism.{Ast, Entity}

  def router_module(schema, opts) do
    openapi_module = openapi_module_name(opts)

    routes = routes(schema)

    quote do
      defmodule Router do
        use Plug.Router

        @json "application/json"

        plug(Plug.Telemetry, event_prefix: [:graphism, :rest])
        plug(:match)

        plug(Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json, Absinthe.Plug.Parser],
          pass: ["*/*"],
          json_decoder: Jason
        )

        plug(:dispatch)

        unquote_splicing(routes)

        get("/openapi.json", to: unquote(openapi_module))

        match _ do
          send_json(unquote(Ast.var(:conn)), %{reason: :no_route}, 404)
        end

        defp send_json(conn, body, status \\ 200) do
          conn
          |> put_resp_content_type(@json)
          |> send_resp(status, Jason.encode!(body))
        end
      end
    end
  end

  def handler_modules(e, _schema, _hooks, _opts) do
    List.flatten(standard_handlers(e) ++ custom_handlers(e))
  end

  def openapi_module(schema, opts) do
    module_name = openapi_module_name(opts)
    openapi = openapi(schema)

    quote do
      defmodule unquote(module_name) do
        use Plug.Builder

        @json "application/json"
        @openapi unquote(openapi)

        plug(:handle)

        def handle(conn, _opts) do
          conn
          |> put_resp_content_type(@json)
          |> send_resp(200, @openapi)
        end
      end
    end
  end

  def redocui_module(_schema, opts) do
    caller = Keyword.fetch!(opts, :caller)
    module_name = Module.concat([caller.module, RedocUI])

    quote do
      defmodule unquote(module_name) do
        @behaviour Plug
        import Plug.Conn

        @index_html """
        <!doctype html>
        <html>
          <head>
            <title>ReDoc</title
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <link href="https://fonts.googleapis.com/css?family=Montserrat:300,400,700|Roboto:300,400,700" rel="stylesheet">
          </head>
          <body>
            <redoc spec-url="<%= spec_url %>"></redoc>
            <script src="https://cdn.jsdelivr.net/npm/redoc@latest/bundles/redoc.standalone.js"></script>
          </body>
        </html>
        """

        @impl true
        def init(opts) do
          spec_url = Keyword.fetch!(opts, :spec_url)
          [spec_url: spec_url]
        end

        @impl true
        def call(conn, opts) do
          conn
          |> send_resp(200, EEx.eval_string(@index_html, opts))
        end
      end
    end
  end

  defp standard_handlers(e) do
    Enum.map(e[:actions], fn {action, opts} ->
      standard_handler(e, action, opts)
    end)
  end

  defp custom_handlers(_e), do: []

  defp routes(schema), do: Enum.flat_map(schema, fn e -> routes(e, schema) end)

  defp routes(e, schema) do
    List.flatten([standard_routes(e, schema) ++ custom_routes(e, schema)])
  end

  defp standard_routes(e, _schema) do
    Enum.map(e[:actions], fn {action, _opts} ->
      method = method(action)
      path = path(action, e)
      handler = handler(action, e)

      quote do
        unquote(method)(unquote(path), to: unquote(handler))
      end
    end)
  end

  defp custom_routes(_e, _schema), do: []

  defp standard_handler(e, action, _opts) do
    handler = handler(action, e)

    quote do
      defmodule unquote(handler) do
        @moduledoc false
        use Plug.Builder

        @json "application/json"

        plug(:handle)

        def handle(conn, _opts) do
          send_json(conn, %{module: __MODULE__})
        end

        defp send_json(conn, body, status \\ 200) do
          conn
          |> put_resp_content_type(@json)
          |> send_resp(status, Jason.encode!(body))
        end
      end
    end
  end

  defp method(:read), do: :get
  defp method(:list), do: :get
  defp method(:create), do: :post
  defp method(:update), do: :put
  defp method(:delete), do: :delete

  defp path(:read, e), do: item_path(e)
  defp path(:list, e), do: collection_path(e)
  defp path(:create, e), do: collection_path(e)
  defp path(:update, e), do: item_path(e)
  defp path(:delete, e), do: item_path(e)

  defp item_path(e), do: "/#{e[:plural]}/:id"
  defp collection_path(e), do: "/#{e[:plural]}"

  defp handler(action, e) do
    Module.concat([e[:handler_module], Inflex.camelize(action)])
  end

  defp openapi_module_name(opts) do
    caller = Keyword.fetch!(opts, :caller)

    Module.concat([caller.module, OpenApi])
  end

  defp openapi(schema) do
    %{
      openapi: "3.0.0",
      info: %{
        version: "1.0.0",
        title: "",
        license: %{name: "MIT"}
      },
      servers: [
        %{url: "http://localhost:4001/api", description: "Local"}
      ],
      paths: %{},
      components: %{}
    }
    |> openapi_with_schemas(schema)
    |> openapi_with_paths(schema)
    |> Jason.encode!()
  end

  defp openapi_with_schemas(spec, schema) do
    schemas =
      Enum.reduce(schema, %{}, fn e, schemas ->
        object = %{
          type: :object,
          required: e |> Entity.required_fields() |> Entity.names(),
          properties:
            e
            |> Entity.all_fields()
            |> Enum.reduce(%{}, fn f, props ->
              Map.put(props, f[:name], openapi_property(f))
            end)
        }

        array = %{
          type: :array,
          items: %{
            "$ref": "#/components/schemas/#{e[:name]}"
          }
        }

        schemas
        |> Map.put(e[:name], object)
        |> Map.put(e[:plural], array)
      end)

    put_in(spec, [:components, :schemas], schemas)
  end

  defp openapi_with_paths(spec, schema) do
    paths =
      Enum.reduce(schema, %{}, fn e, paths ->
        paths
        |> Map.put(item_path(e), openapi_item_paths(e))
        |> Map.put(collection_path(e), openapi_collection_paths(e))
      end)

    put_in(spec, [:paths], paths)
  end

  defp openapi_item_paths(e) do
    %{}
    |> maybe_with_openapi_read_path(e)
    |> maybe_with_openapi_update_path(e)
  end

  defp openapi_collection_paths(e) do
    %{}
    |> maybe_with_openapi_list_path(e)
    |> maybe_with_openapi_create_path(e)
  end

  defp maybe_with_openapi_read_path(paths, e) do
    case Entity.find_action(e, :read) do
      nil ->
        paths

      _action ->
        Map.put(paths, :get, %{
          summary: "Read a single #{e[:camel_name]}",
          operationId: "read#{e[:display_name]}",
          tags: [e[:plural_camel_name]],
          parameters: [
            %{
              name: "id",
              in: :path,
              required: true,
              description: "The id for the #{e[:camel_name]} to read",
              schema: %{type: :string}
            }
          ]
        })
    end
  end

  defp maybe_with_openapi_update_path(paths, _e), do: paths

  defp maybe_with_openapi_list_path(paths, e) do
    case Entity.find_action(e, :list) do
      nil ->
        paths

      _action ->
        Map.put(paths, :get, %{
          summary: "List multiple #{e[:plural_camel_name]}",
          operationId: "list#{e[:display_name]}",
          tags: [e[:plural_camel_name]],
          parameters: [
            %{}
          ]
        })
    end
  end

  defp maybe_with_openapi_create_path(paths, _e), do: paths

  defp openapi_property(opts) do
    %{type: openapi_type(opts[:kind])}
  end

  defp openapi_type(:integer), do: :integer
  defp openapi_type(:float), do: :number
  defp openapi_type(:boolean), do: :boolean
  defp openapi_type(:has_many), do: :array
  defp openapi_type(_), do: :string
end
