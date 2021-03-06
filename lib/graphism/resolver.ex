defmodule Graphism.Resolver do
  @moduledoc "Produces Graphql resolver code"

  alias Graphism.{Ast, Entity}

  def resolver_module(e, schema, opts) do
    api_module = e[:api_module]
    hooks = Keyword.fetch!(opts, :hooks)

    resolver_funs =
      []
      |> with_resolver_pagination_fun()
      |> with_resolver_scope_results_fun()
      |> with_resolver_auth_funs(e, schema, hooks)
      |> with_resolver_inlined_relations_funs(e, schema, api_module)
      |> with_resolver_list_funs(e, schema, api_module, hooks)
      |> with_resolver_aggregate_funs(e, schema, api_module)
      |> with_resolver_read_funs(e, schema, api_module)
      |> with_resolver_create_fun(e, schema, api_module, opts)
      |> with_resolver_update_fun(e, schema, api_module, opts)
      |> with_resolver_delete_fun(e, schema, api_module)
      |> with_resolver_custom_funs(e, schema, api_module, hooks)
      |> List.flatten()

    quote do
      defmodule unquote(e[:resolver_module]) do
        (unquote_splicing(resolver_funs))
      end
    end
  end

  defp with_resolver_pagination_fun(funs) do
    [
      quote do
        @pagination_fields [:offset, :limit, :sort_by, :sort_direction]

        def context_with_pagination(unquote(Ast.var(:args)), context) do
          Enum.reduce(@pagination_fields, context, fn field, acc ->
            Map.put(acc, field, Map.get(unquote(Ast.var(:args)), field, nil))
          end)
        end
      end
      | funs
    ]
  end

  defp with_resolver_scope_results_fun(funs) do
    [
      quote do
        defp scope_results(mod, items, context) do
          entity = context.graphism.entity
          context = put_in(context, [:graphism, :action], :read)
          meta = %{entity: entity, kind: :scope, value: :undefined}

          {:ok,
           Enum.filter(items, fn item ->
             context = Map.put(context, entity, item)

             :telemetry.span([:graphism, :allow], meta, fn ->
               {mod.allow?(%{}, context), meta}
             end)
           end)}
        end
      end
      | funs
    ]
  end

  defp with_resolver_auth_funs(funs, e, schema, hooks) do
    action_resolver_auth_funs =
      (e[:actions] ++ e[:custom_actions])
      |> Enum.reject(fn {name, _} -> name == :list end)
      |> Enum.map(fn {name, opts} ->
        resolver_auth_fun(name, opts, e, schema, hooks)
      end)

    funs ++
      ([
         action_resolver_auth_funs,
         resolver_list_auth_funs(e, schema, hooks)
       ]
       |> List.flatten()
       |> Enum.reject(&is_nil/1))
  end

  defp resolver_list_auth_funs(e, schema, hooks) do
    e[:actions]
    |> Enum.filter(fn {action, _opts} -> action == :list end)
    |> Enum.flat_map(fn {_, opts} ->
      [
        resolver_list_all_auth_fun(e, opts, schema, hooks),
        resolver_list_by_parent_auth_funs(e, opts, schema, hooks)
      ]
    end)
  end

  defp simple_auth_context(e, action) do
    quote do
      context =
        context
        |> Map.drop([:__absinthe_plug__, :loader, :pubsub])
        |> Map.put(:graphism, %{
          entity: unquote(e[:name]),
          action: unquote(action),
          schema: unquote(e[:schema_module])
        })
    end
  end

  defp auth_mod_invocation(mod, e, fun_name) do
    quote do
      meta = %{entity: unquote(e[:name]), kind: :action, value: unquote(fun_name)}

      :telemetry.span([:graphism, :allow], meta, fn ->
        {with false <- unquote(mod).allow?(unquote(Ast.var(:args)), context) do
           {:error, :unauthorized}
         end, meta}
      end)
    end
  end

  defp resolver_list_all_auth_fun(e, opts, _schema, hooks) do
    mod = Entity.allow_hook!(e, opts, :list, hooks)

    quote do
      defp should_list?(unquote(Ast.var(:args)), context) do
        unquote(auth_mod_invocation(mod, e, :should_list))
      end
    end
  end

  defp resolver_list_by_parent_auth_funs(e, opts, _schema, hooks) do
    mod = Entity.allow_hook!(e, opts, :list, hooks)

    e
    |> Entity.parent_relations()
    |> Enum.map(fn rel ->
      fun_name = String.to_atom("should_list_by_#{rel[:name]}?")

      ast =
        quote do
          defp unquote(fun_name)(unquote(Ast.var(:args)), context) do
            unquote(auth_mod_invocation(mod, e, fun_name))
          end
        end

      ast
    end)
  end

  defp auth_fun_entities_arg_names(e, action, opts) do
    cond do
      action == :update ->
        (e |> Entity.parent_relations() |> Entity.names()) ++ [e[:name]]

      action == :create ->
        e |> Entity.parent_relations() |> Entity.names()

      action == :read || action == :delete || has_id_arg?(opts) ->
        [e[:name]]

      true ->
        []
    end
  end

  defp resolver_auth_fun(action, opts, e, _schema, hooks) do
    mod = Entity.allow_hook!(e, opts, action, hooks)

    fun_name = String.to_atom("should_#{action}?")

    entities_var_names = auth_fun_entities_arg_names(e, action, opts)

    {empty_data, data_with_args, context_with_data} =
      case entities_var_names do
        [] ->
          {nil, nil, nil}

        _ ->
          {
            quote do
              data = %{}
            end,
            Enum.map(entities_var_names, fn e ->
              quote do
                data = Map.put(data, unquote(e), unquote(Ast.var(e)))
              end
            end),
            quote do
              context = Map.merge(context, data)
            end
          }
      end

    quote do
      def unquote(fun_name)(
            unquote_splicing(Ast.vars(entities_var_names)),
            unquote(Ast.var(:args)),
            context
          ) do
        (unquote_splicing(
           [
             empty_data,
             data_with_args,
             context_with_data,
             auth_mod_invocation(mod, e, fun_name)
           ]
           |> List.flatten()
           |> Enum.reject(&is_nil/1)
         ))
      end
    end
  end

  defp inline_relation_resolver_call(resolver_module, action) do
    quote do
      case unquote(resolver_module).unquote(action)(
             graphql.parent,
             child,
             graphql.resolution
           ) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, e} ->
          {:halt, {:error, e}}
      end
    end
  end

  defp with_resolver_inlined_relations_funs(funs, e, schema, _api_module) do
    (Enum.map([:create, :update], fn action ->
       case inlined_children_for_action(e, action) do
         [] ->
           nil

         rels ->
           fun_name = String.to_atom("#{action}_inline_relations")

           [
             quote do
               def unquote(fun_name)(unquote(Macro.var(e[:name], nil)), unquote(Ast.var(:args)), graphql) do
                 with unquote_splicing(
                        Enum.map(rels, fn rel ->
                          fun_name = String.to_atom("#{action}_inline_relation")

                          quote do
                            :ok <-
                              unquote(fun_name)(
                                unquote(Macro.var(e[:name], nil)),
                                unquote(Ast.var(:args)),
                                unquote(rel[:name]),
                                graphql
                              )
                          end
                        end)
                      ) do
                   :ok
                 end
               end
             end
             | Enum.map(rels, fn rel ->
                 target = Entity.find_entity!(schema, rel[:target])
                 resolver_module = target[:resolver_module]
                 parent_rel = Entity.find_relation_by_kind_and_target!(target, :belongs_to, e[:name])

                 children_rels =
                   quote do
                     Enum.reduce_while(children, :ok, fn child, _ ->
                       # populate the parent relation
                       # and delete to the child entity resolver
                       child =
                         Map.put(
                           child,
                           unquote(parent_rel[:name]),
                           unquote(Macro.var(e[:name], nil)).id
                         )

                       # if the child input contains an id,
                       # and we are updating, then we assume we want to update,
                       # if not we assume we want to create.
                       unquote(
                         case action do
                           :update ->
                             quote do
                               case Map.get(child, :id, nil) do
                                 nil ->
                                   unquote(inline_relation_resolver_call(resolver_module, :create))

                                 _ ->
                                   unquote(inline_relation_resolver_call(resolver_module, action))
                               end
                             end

                           _ ->
                             inline_relation_resolver_call(resolver_module, action)
                         end
                       )
                     end)
                   end

                 fun_name = String.to_atom("#{action}_inline_relation")

                 quote do
                   defp unquote(fun_name)(
                          unquote(Macro.var(e[:name], nil)),
                          unquote(Ast.var(:args)),
                          unquote(rel[:name]),
                          graphql
                        ) do
                     unquote(
                       quote do
                         case Map.get(unquote(Ast.var(:args)), unquote(rel[:name]), nil) do
                           nil ->
                             :ok

                           children ->
                             unquote(children_rels)
                         end
                       end
                     )
                   end
                 end
               end)
           ]
       end
     end)
     |> List.flatten()
     |> Enum.reject(&is_nil/1)) ++ funs
  end

  defp resolver_list_fun(e, _schema, api_module, hooks) do
    action_opts = Entity.action_for(e, :list)
    scope_mod = Entity.scope_hook!(e, action_opts, :list, hooks)

    quote do
      def list(_, unquote(Ast.var(:args)), %{context: context}) do
        unquote(simple_auth_context(e, :list))

        with true <- should_list?(unquote(Ast.var(:args)), context),
             context <- context_with_pagination(unquote(Ast.var(:args)), context),
             {:ok, items} <- unquote(api_module).list(context) do
          scope_results(unquote(scope_mod), items, context)
        end
      end
    end
  end

  defp resolver_list_by_relation_funs(e, schema, api_module, hooks) do
    action_opts = Entity.action_for(e, :list)
    scope_mod = Entity.scope_hook!(e, action_opts, :list, hooks)

    e
    |> Entity.parent_relations()
    |> Enum.map(fn rel ->
      target = Entity.find_entity!(schema, rel[:target])
      fun_name = String.to_atom("list_by_#{rel[:name]}")
      auth_fun_name = String.to_atom("should_list_by_#{rel[:name]}?")

      quote do
        def unquote(fun_name)(_, unquote(Ast.var(:args)), %{context: context}) do
          unquote(simple_auth_context(e, :list))

          with {:ok, unquote(Ast.var(rel))} <-
                 unquote(target[:api_module]).get_by_id(unquote(Ast.var(:args)).unquote(rel[:name])),
               true <- unquote(auth_fun_name)(unquote(Ast.var(rel)), context),
               context <- context_with_pagination(unquote(Ast.var(:args)), context),
               {:ok, items} <- unquote(api_module).unquote(fun_name)(unquote(Ast.var(rel)).id, context) do
            scope_results(unquote(scope_mod), items, context)
          end
        end
      end
    end)
  end

  defp resolver_list_by_non_unique_keys_funs(e, _schema, api_module, hooks) do
    action_opts = Entity.action_for(e, :list)
    scope_mod = Entity.scope_hook!(e, action_opts, :list, hooks)

    e
    |> Entity.non_unique_keys()
    |> Enum.map(fn key ->
      fun_name = Entity.list_by_key_fun_name(key)

      quote do
        def unquote(fun_name)(_, unquote(Ast.var(:args)), %{context: context}) do
          unquote(simple_auth_context(e, :list))

          with unquote_splicing(
                 [
                   should_invocation(e, :list),
                   extract_args_for_entity_key(key),
                   context_with_pagination_invocation(),
                   api_call_invocation(fun_name, api_module, args: key[:fields])
                 ]
                 |> List.flatten()
               ) do
            scope_results(unquote(scope_mod), items, context)
          end
        end
      end
    end)
  end

  defp with_resolver_list_funs(funs, e, schema, api_module, hooks) do
    with_entity_funs(funs, e, :list, fn ->
      [resolver_list_fun(e, schema, api_module, hooks)] ++
        resolver_list_by_relation_funs(e, schema, api_module, hooks) ++
        resolver_list_by_non_unique_keys_funs(e, schema, api_module, hooks)
    end)
  end

  defp resolver_aggregate_all_fun(e, _schema, api_module) do
    quote do
      def aggregate_all(_, unquote(Ast.var(:args)), %{context: context}) do
        unquote(simple_auth_context(e, :list))

        with true <- should_list?(unquote(Ast.var(:args)), context) do
          unquote(api_module).aggregate(context)
        end
      end
    end
  end

  defp resolver_aggregate_by_relation_funs(e, schema, api_module) do
    e
    |> Entity.parent_relations()
    |> Enum.map(fn rel ->
      target = Entity.find_entity!(schema, rel[:target])
      fun_name = String.to_atom("aggregate_by_#{rel[:name]}")
      auth_fun_name = String.to_atom("should_list_by_#{rel[:name]}?")

      quote do
        def unquote(fun_name)(_, unquote(Ast.var(:args)), %{context: context}) do
          unquote(simple_auth_context(e, :list))

          with {:ok, unquote(Ast.var(rel))} <-
                 unquote(target[:api_module]).get_by_id(unquote(Ast.var(:args)).unquote(rel[:name])),
               true <- unquote(auth_fun_name)(unquote(Ast.var(rel)), context) do
            unquote(api_module).unquote(fun_name)(
              unquote(Ast.var(rel)).id,
              context
            )
          end
        end
      end
    end)
  end

  defp resolver_aggregate_by_non_unique_key_funs(e, _schema, api_module) do
    e
    |> Entity.non_unique_keys()
    |> Enum.map(fn key ->
      fun_name = Entity.aggregate_by_key_fun_name(key)

      quote do
        def unquote(fun_name)(_, unquote(Ast.var(:args)), %{context: context}) do
          unquote(simple_auth_context(e, :list))

          with unquote_splicing(
                 [
                   should_invocation(e, :list),
                   extract_args_for_entity_key(key)
                 ]
                 |> List.flatten()
               ) do
            unquote(api_call_invocation(fun_name, api_module, args: key[:fields], with: false))
          end
        end
      end
    end)
  end

  defp with_resolver_aggregate_funs(funs, e, schema, api_module) do
    with_entity_funs(funs, e, :list, fn ->
      [resolver_aggregate_all_fun(e, schema, api_module)] ++
        resolver_aggregate_by_relation_funs(e, schema, api_module) ++
        resolver_aggregate_by_non_unique_key_funs(e, schema, api_module)
    end)
  end

  defp inlined_children_for_action(e, action) do
    e[:relations]
    |> Enum.filter(fn rel ->
      :has_many == rel[:kind] &&
        Entity.inline_relation?(rel, action)
    end)
  end

  defp with_entity_fetch(e) do
    quote do
      {:ok, unquote(Ast.var(e))} <-
        unquote(e[:api_module]).get_by_id(unquote(Ast.var(:args)).id)
    end
  end

  defp has_id_arg?(opts) do
    Enum.member?(opts[:args] || [], :id)
  end

  defp with_custom_action_entity_fetch(e, opts, _schema) do
    case has_id_arg?(opts) do
      true ->
        [
          quote do
            {:ok, unquote(Ast.var(e))} <-
              unquote(e[:api_module]).get_by_id(unquote(Ast.var(:args)).id)
          end,
          quote do
            unquote(Ast.var(:args)) <- Map.put(unquote(Ast.var(:args)), unquote(e[:name]), unquote(Ast.var(e)))
          end,
          quote do
            unquote(Ast.var(:args)) <- Map.drop(unquote(Ast.var(:args)), [:id])
          end
        ]

      false ->
        nil
    end
  end

  defp with_entity_fetch(e, attr) do
    fun_name = String.to_atom("get_by_#{attr}")

    args =
      ((e[:opts][:scope] || []) ++ [attr])
      |> Enum.map(fn arg ->
        quote do
          unquote(Ast.var(:args)).unquote(arg)
        end
      end)

    quote do
      {:ok, unquote(Ast.var(e))} <-
        unquote(e[:api_module]).unquote(fun_name)(unquote_splicing(args))
    end
  end

  # Builds a series of with clauses that fetch entity parent
  # dependencies required in order to either create or update
  # the entity
  defp with_parent_entities_fetch(e, schema, opts) do
    e
    |> Entity.parent_relations()
    |> with_parent_entities_fetch_from_rels(e, schema, opts)
  end

  defp with_computed_attributes(e, _schema, _opts) do
    e[:attributes]
    |> Enum.filter(&Entity.computed?/1)
    |> Enum.flat_map(fn attr ->
      cond do
        attr[:opts][:using] != nil ->
          mod = attr[:opts][:using]

          [
            quote do
              {:ok, unquote(Ast.var(attr))} <- unquote(mod).execute(context)
            end,
            quote do
              unquote(Ast.var(:args)) <-
                Map.put(unquote(Ast.var(:args)), unquote(attr[:name]), unquote(Ast.var(attr)))
            end
          ]

        attr[:opts][:from_context] != nil ->
          from = attr[:opts][:from_context]

          [
            quote do
              unquote(Ast.var(attr)) <- get_in(context, unquote(from))
            end,
            quote do
              unquote(Ast.var(attr)) <- Map.get(unquote(Ast.var(attr)), :id)
            end,
            quote do
              unquote(Ast.var(:args)) <-
                Map.put(unquote(Ast.var(:args)), unquote(attr[:name]), unquote(Ast.var(attr)))
            end
          ]

        true ->
          []
      end
    end)
  end

  defp with_custom_parent_entities_fetch(e, schema, opts) do
    opts[:args]
    |> Enum.map(&Entity.relation?(e, &1))
    |> Enum.reject(&is_nil/1)
    |> with_parent_entities_fetch_from_rels(e, schema, opts)
  end

  defp with_parent_entities_fetch_from_rels(rels, e, schema, opts \\ []) do
    api_module = e[:api_module]

    Enum.map(rels, fn rel ->
      case Entity.computed?(rel) do
        true ->
          cond do
            rel[:opts][:using] != nil ->
              mod = rel[:opts][:using]

              quote do
                {:ok, unquote(Ast.var(rel))} <- unquote(mod).execute(context)
              end

            rel[:opts][:from] != nil ->
              [parent_rel, rel_name] =
                case rel[:opts][:from] do
                  [parent_rel, rel_name] -> [parent_rel, rel_name]
                  parent_rel -> [parent_rel, rel[:name]]
                end

              relation = Entity.relation!(e, parent_rel)
              target_entity = relation[:target]

              target = Entity.find_entity!(schema, target_entity)
              api_module = target[:api_module]

              quote do
                unquote(Ast.var(rel)) <-
                  unquote(api_module).relation(unquote(Ast.var(parent_rel)), unquote(rel_name))
              end

            rel[:opts][:from_context] != nil ->
              from = rel[:opts][:from_context]

              quote do
                unquote(Ast.var(rel)) <- get_in(context, unquote(from))
              end

            true ->
              raise "relation #{rel[:name]} of #{e[:name]} is computed but does not specify a :using or a :from option"
          end

        false ->
          target = Entity.find_entity!(schema, rel[:target])
          {arg_name, _, lookup_fun} = Entity.lookup_arg(schema, e, rel, opts[:action])

          quote do
            {:ok, unquote(Ast.var(rel))} <-
              unquote(
                case Entity.optional?(rel) do
                  false ->
                    case opts[:action] do
                      :update ->
                        quote do
                          case Map.get(unquote(Ast.var(:args)), unquote(arg_name), nil) do
                            nil ->
                              {:ok, unquote(api_module).relation(unquote(Ast.var(e)), unquote(rel[:name]))}

                            "" ->
                              {:ok, unquote(api_module).relation(unquote(Ast.var(e)), unquote(rel[:name]))}

                            key ->
                              unquote(target[:api_module]).unquote(lookup_fun)(key)
                          end
                        end

                      _ ->
                        quote do
                          unquote(target[:api_module]).unquote(lookup_fun)(unquote(Ast.var(:args)).unquote(arg_name))
                        end
                    end

                  true ->
                    quote do
                      case Map.get(unquote(Ast.var(:args)), unquote(arg_name), nil) do
                        nil ->
                          {:ok, nil}

                        "" ->
                          {:ok, nil}

                        key ->
                          unquote(target[:api_module]).unquote(lookup_fun)(key)
                      end
                    end
                end
              )
          end
      end
    end)
  end

  # Builds a map of arguments where keys for parent entities
  # have been removed, since they should have already been resolved
  # by their ids.
  defp with_args_without_parents(e) do
    case e |> Entity.parent_relations() |> Entity.names() do
      [] ->
        nil

      names ->
        quote do
          unquote(Ast.var(:args)) <- Map.drop(unquote(Ast.var(:args)), unquote(names))
        end
    end
  end

  defp with_custom_args_with_parents(e, opts, _schema) do
    opts[:args]
    |> Enum.map(&Entity.relation?(e, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn rel ->
      quote do
        unquote(Ast.var(:args)) <- Map.put(unquote(Ast.var(:args)), unquote(rel[:name]), unquote(Ast.var(rel)))
      end
    end)
  end

  defp maybe_with_args_with_autogenerated_id!(e) do
    case Entity.client_ids?(e) do
      false ->
        quote do
          unquote(Ast.var(:args)) <- Map.put(unquote(Ast.var(:args)), :id, Ecto.UUID.generate())
        end

      true ->
        nil
    end
  end

  defp maybe_with_with_autogenerated_id(_e, opts, _schema) do
    case has_id_arg?(opts) do
      false ->
        quote do
          unquote(Ast.var(:args)) <-
            Map.put_new_lazy(unquote(Ast.var(:args)), :id, fn ->
              Ecto.UUID.generate()
            end)
        end

      true ->
        nil
    end
  end

  defp with_args_without_id() do
    quote do
      unquote(Ast.var(:args)) <- Map.drop(unquote(Ast.var(:args)), [:id])
    end
  end

  defp should_invocation(e, action, opts \\ []) do
    fun_name = String.to_atom("should_#{action}?")

    quote do
      true <-
        unquote(fun_name)(
          unquote_splicing(auth_fun_entities_arg_names(e, action, opts) |> Ast.vars()),
          unquote(Ast.var(:args)),
          context
        )
    end
  end

  defp resolver_fun_args_for_action(e, action) do
    inlined_children = inlined_children_for_action(e, action)

    case inlined_children do
      [] ->
        {quote do
           _parent
         end,
         quote do
           %{context: context}
         end}

      _ ->
        {quote do
           parent
         end,
         quote do
           %{context: context} = resolution
         end}
    end
  end

  defp with_resolver_create_fun(funs, e, schema, api_module, opts) do
    with_entity_funs(funs, e, :create, fn ->
      inlined_children = inlined_children_for_action(e, :create)

      {parent_var, resolution_var} = resolver_fun_args_for_action(e, :create)

      quote do
        def create(unquote(parent_var), unquote(Ast.var(:args)), unquote(resolution_var)) do
          unquote(simple_auth_context(e, :create))

          with unquote_splicing(
                 [
                   with_parent_entities_fetch(e, schema, action: :create),
                   with_args_without_parents(e),
                   maybe_with_args_with_autogenerated_id!(e),
                   with_computed_attributes(e, schema, opts),
                   should_invocation(e, :create)
                 ]
                 |> List.flatten()
                 |> Enum.reject(&is_nil/1)
               ) do
            unquote(
              case inlined_children do
                [] ->
                  quote do
                    unquote(api_module).create(
                      unquote_splicing(
                        (e |> Entity.parent_relations() |> Entity.names() |> Ast.vars()) ++ [Ast.var(:args)]
                      )
                    )
                  end

                children ->
                  quote do
                    {children_args, args} =
                      Map.split(
                        unquote(Ast.var(:args)),
                        unquote(Entity.names(children))
                      )

                    unquote(opts[:repo]).transaction(fn ->
                      with {:ok, unquote(Ast.var(e))} <-
                             unquote(api_module).create(
                               unquote_splicing(
                                 (e |> Entity.parent_relations() |> Entity.names() |> Ast.vars()) ++
                                   [Ast.var(:args)]
                               )
                             ),
                           :ok <-
                             create_inline_relations(
                               unquote(Ast.var(e)),
                               children_args,
                               %{parent: parent, resolution: resolution}
                             ) do
                        unquote(Ast.var(e))
                      else
                        {:error, changeset} ->
                          unquote(opts[:repo]).rollback(changeset)
                      end
                    end)
                  end
              end
            )
          end
        end
      end
    end)
  end

  defp with_resolver_update_fun(funs, e, schema, api_module, opts) do
    with_entity_funs(funs, e, :update, fn ->
      inlined_children = inlined_children_for_action(e, :update)

      {parent_var, resolution_var} = resolver_fun_args_for_action(e, :update)

      ast =
        quote do
          def update(unquote(parent_var), unquote(Ast.var(:args)), unquote(resolution_var)) do
            unquote(simple_auth_context(e, :update))

            with unquote_splicing(
                   [
                     with_entity_fetch(e),
                     with_parent_entities_fetch(e, schema, action: :update),
                     with_args_without_parents(e),
                     with_args_without_id(),
                     should_invocation(e, :update)
                   ]
                   |> List.flatten()
                   |> Enum.reject(&is_nil/1)
                 ) do
              unquote(
                case inlined_children do
                  [] ->
                    quote do
                      unquote(api_module).update(
                        unquote_splicing(
                          (e |> Entity.parent_relations() |> Entity.names() |> Ast.vars()) ++
                            [Ast.var(e), Ast.var(:args)]
                        )
                      )
                    end

                  children ->
                    quote do
                      {children_args, args} =
                        Map.split(
                          unquote(Ast.var(:args)),
                          unquote(Entity.names(children))
                        )

                      unquote(opts[:repo]).transaction(fn ->
                        with {:ok, unquote(Ast.var(e))} <-
                               unquote(api_module).update(
                                 unquote_splicing(
                                   (e |> Entity.parent_relations() |> Entity.names() |> Ast.vars()) ++
                                     [Ast.var(e), Ast.var(:args)]
                                 )
                               ),
                             :ok <-
                               update_inline_relations(
                                 unquote(Ast.var(e)),
                                 children_args,
                                 %{parent: parent, resolution: resolution}
                               ) do
                          unquote(Ast.var(e))
                        else
                          {:error, changeset} ->
                            unquote(opts[:repo]).rollback(changeset)
                        end
                      end)
                    end
                end
              )
            end
          end
        end

      ast
    end)
  end

  defp with_resolver_delete_fun(funs, e, _schema, api_module) do
    with_entity_funs(funs, e, :delete, fn ->
      quote do
        def delete(_parent, unquote(Ast.var(:args)), %{context: context}) do
          unquote(simple_auth_context(e, :delete))

          with unquote_splicing(
                 [
                   with_entity_fetch(e),
                   should_invocation(e, :delete)
                 ]
                 |> List.flatten()
                 |> Enum.reject(&is_nil/1)
               ) do
            unquote(api_module).delete(unquote(Ast.var(e)))
          end
        end
      end
    end)
  end

  defp with_resolver_custom_funs(funs, e, schema, api_module, hooks) do
    custom_queries_funs =
      e
      |> Entity.custom_queries()
      |> Enum.flat_map(fn {name, opts} ->
        [
          resolver_custom_query_fun(e, name, opts, api_module, hooks, schema),
          resolver_custom_query_aggregate_fun(e, name, opts, api_module, hooks, schema)
        ]
      end)

    custom_mutations_funs =
      e
      |> Entity.custom_mutations()
      |> Enum.map(fn {name, opts} ->
        resolver_custom_mutation_fun(e, name, opts, api_module, hooks, schema)
      end)

    custom_queries_funs ++ custom_mutations_funs ++ funs
  end

  defp context_with_pagination_invocation do
    quote do
      context <- context_with_pagination(unquote(Ast.var(:args)), context)
    end
  end

  defp api_call_invocation(action, api_module, opts \\ []) do
    args = Keyword.get(opts, :args, [:args])

    case Keyword.get(opts, :with, true) do
      true ->
        quote do
          {:ok, items} <- unquote(api_module).unquote(action)(unquote_splicing(Ast.vars(args)), context)
        end

      false ->
        quote do
          unquote(api_module).unquote(action)(unquote_splicing(Ast.vars(args)), context)
        end
    end
  end

  defp extract_args_for_entity_key(key) do
    Enum.map(key[:fields], fn field ->
      quote do
        unquote(Ast.var(field)) <- Map.fetch!(unquote(Ast.var(:args)), unquote(field))
      end
    end)
  end

  defp resolver_custom_query_fun(e, action, opts, api_module, hooks, _schema) do
    scope_mod = Entity.scope_hook!(e, opts, action, hooks)

    quote do
      def unquote(action)(_, unquote(Ast.var(:args)), %{context: context}) do
        unquote(simple_auth_context(e, action))

        with unquote_splicing([
               should_invocation(e, action),
               context_with_pagination_invocation(),
               api_call_invocation(action, api_module)
             ]) do
          scope_results(unquote(scope_mod), items, context)
        end
      end
    end
  end

  defp resolver_custom_query_aggregate_fun(e, action, _opts, api_module, _hooks, _schema) do
    fun_name = String.to_atom("aggregate_#{action}")

    quote do
      def unquote(fun_name)(_, unquote(Ast.var(:args)), %{context: context}) do
        unquote(simple_auth_context(e, action))

        with unquote_splicing([
               should_invocation(e, action)
             ]) do
          unquote(api_module).unquote(fun_name)(unquote(Ast.var(:args)), context)
        end
      end
    end
  end

  defp resolver_custom_mutation_fun(e, action, opts, api_module, _hooks, schema) do
    opts = Keyword.put(opts, :action, action)

    quote do
      def unquote(action)(_, unquote(Ast.var(:args)), %{context: context}) do
        unquote(simple_auth_context(e, action))

        with unquote_splicing(
               [
                 with_custom_action_entity_fetch(e, opts, schema),
                 with_custom_parent_entities_fetch(e, schema, opts),
                 with_custom_args_with_parents(e, opts, schema),
                 maybe_with_with_autogenerated_id(e, opts, schema),
                 should_invocation(e, action, opts)
               ]
               |> List.flatten()
               |> Enum.reject(&is_nil/1)
             ) do
          unquote(api_module).unquote(action)(unquote(Ast.var(:args)), context)
        end
      end
    end
  end

  defp with_resolver_read_funs(funs, e, _schema, _api_module) do
    with_entity_funs(funs, e, :read, fn ->
      [
        get_by_id_resolver_fun(e)
      ] ++ get_by_key_resolver_funs(e) ++ get_by_attribute_resolver_funs(e)
    end)
  end

  defp with_entity_funs(funs, e, action, fun) do
    case Entity.action?(e, action) do
      true ->
        case fun.() do
          [_ | _] = more_funs ->
            more_funs ++ [funs]

          single_fun ->
            [single_fun | funs]
        end

      false ->
        funs
    end
  end

  defp get_by_id_resolver_fun(e) do
    quote do
      def get_by_id(_, unquote(Ast.var(:args)), %{context: context}) do
        unquote(simple_auth_context(e, :read))

        with unquote_splicing([
               with_entity_fetch(e),
               should_invocation(e, :read)
             ]) do
          {:ok, unquote(Ast.var(e))}
        end
      end
    end
  end

  defp get_by_key_resolver_funs(e) do
    e
    |> Entity.unique_keys()
    |> Enum.map(fn key ->
      fun_name = Entity.get_by_key_fun_name(key)

      args =
        Enum.map(key[:fields], fn name ->
          quote do
            unquote(Ast.var(:args)).unquote(Ast.var(name))
          end
        end)

      api_call =
        quote do
          {:ok, unquote(Ast.var(e))} <-
            unquote(e[:api_module]).unquote(fun_name)(unquote_splicing(args))
        end

      quote do
        def unquote(fun_name)(_, unquote(Ast.var(:args)), %{context: context}) do
          unquote(simple_auth_context(e, :list))

          with unquote_splicing([
                 api_call,
                 should_invocation(e, :read)
               ]) do
            {:ok, unquote(Ast.var(e))}
          end
        end
      end
    end)
  end

  defp get_by_attribute_resolver_funs(e) do
    e[:attributes]
    |> Enum.filter(&Entity.unique?/1)
    |> Enum.map(fn attr ->
      attr_name = attr[:name]
      fun_name = String.to_atom("get_by_#{attr[:name]}")

      quote do
        def unquote(fun_name)(
              _,
              unquote(Ast.var(:args)),
              %{context: context}
            ) do
          unquote(simple_auth_context(e, :read))

          with unquote_splicing([
                 with_entity_fetch(e, attr_name),
                 should_invocation(e, :read)
               ]) do
            {:ok, unquote(Ast.var(e))}
          end
        end
      end
    end)
  end
end
