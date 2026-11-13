-- Carousel posts: several photos in one post, swiped through in the feed.
--
-- `gallery` is an ordered list of images, each {"path", "width", "height"}
-- (paths in the creatorapp-media bucket). For a carousel the post still sets
-- media_kind = 'image' and media_path = the first photo, so app builds that
-- predate carousels simply show the first photo.

alter table creatorapp.posts
  add column gallery jsonb not null default '[]'::jsonb,
  add constraint posts_gallery_is_list check (
    jsonb_typeof(gallery) = 'array' and jsonb_array_length(gallery) <= 10
  );
