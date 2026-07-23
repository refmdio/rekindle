defmodule Rekindle.ArtifactStore.Member do
  @moduledoc false
  @enforce_keys [:path, :sha256, :size, :mode]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          mode: :regular | :executable_owner
        }
end

defmodule Rekindle.ArtifactStore.Descriptor do
  @moduledoc false
  @enforce_keys [
    :artifact_id,
    :manifest_path,
    :manifest_digest,
    :support_level,
    :profile,
    :source_revision,
    :members
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          artifact_id: String.t(),
          manifest_path: String.t(),
          manifest_digest: String.t(),
          support_level: Rekindle.support_level(),
          profile: String.t(),
          source_revision: non_neg_integer(),
          members: [Rekindle.ArtifactStore.Member.t()]
        }
end

defmodule Rekindle.ArtifactStore.Staging do
  @moduledoc false
  @enforce_keys [:store, :attempt_id, :generation_id, :target, :path]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          store: GenServer.server(),
          attempt_id: String.t(),
          generation_id: String.t(),
          target: Rekindle.target(),
          path: Path.t()
        }
end

defmodule Rekindle.ArtifactStore.Lease do
  @moduledoc false
  @enforce_keys [:store, :token, :target, :generation_id, :artifact_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          store: GenServer.server(),
          token: reference(),
          target: Rekindle.target(),
          generation_id: String.t(),
          artifact_id: String.t()
        }
end
