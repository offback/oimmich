-- oimmich: user configuration
-- Saved changes reload the screensaver automatically. Every option shown here is
-- a default; delete a line to fall back to it.

return {
  server = {
    url = "https://immich.example.com",
    -- The API key lives in its own 0600 file, never in this repo.
    -- Create it: Immich > Account Settings > API Keys > New (asset.read, album.read)
    api_key_file = "~/.config/omarchy/oimmich/api-key",
    verify_tls = true,
  },

  source = {
    -- Empty = every photo in the library. Names or UUIDs both work, quoted:
    --   albums = {"Camera", "88ca12a5-cff5-4eec-9814-30d63cc9ac42"},
    albums = {},
    -- "shuffle" | "newest" | "oldest"
    mode = "shuffle",
    -- Skip videos and live-photo motion assets (stills only).
    stills_only = true,
    -- Optional ISO date range, e.g. from = "2024-01-01".
    from = nil,
    to = nil,
  },

  display = {
    -- Seconds of inactivity before the slideshow starts (0 = never).
    idle_seconds = 150,
    seconds_per_photo = 30,
    crossfade_ms = 1200,
    -- Very slow zoom/pan, the "living picture" effect.
    ken_burns = true,
    order = "shuffle",   -- "shuffle" | "sequential"
    prefetch = 3,
  },

  sizing = {
    -- "preview" (~1440px, right for 1080p/1440p) | "fullsize" (4K panels)
    quality = "preview",
    -- What fills the space the photo cannot cover.
    fill = "blur",       -- "blur" | "black" | "solid"
    blur_strength = 0.8,
    darken = 0.12,
  },

  overlay = {
    clock = false,       -- time, bottom-left by default
    date = false,        -- weekday and date
    caption = false,     -- the photo's own date and place, when Immich has it
    position = "bottom-left",  -- bottom-left | bottom-right | top-left | top-right
  },

  monitors = {
    mode = "same",       -- "same" | "independent"
  },

  cache = {
    dir = "~/.cache/oimmich",
    max_gb = 2,
    -- How often to refresh the photo list from Immich, in minutes.
    refresh_minutes = 60,
  },
}
