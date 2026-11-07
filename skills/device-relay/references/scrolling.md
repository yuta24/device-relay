# Scrolling example

```sh
relay health                          # check screen.width / height
relay swipe 200 700 200 250           # from bottom to top (moves the content up)
relay find --label "Privacy" --type button
```

An element off the screen is `offscreen`, so repeat swiping and observing until `find` locates it. After a swipe, let the momentum scroll stop before tapping (about 2 seconds; this is the one place for a fixed wait, such as a `sleep 2` step in `relay run`): a tap during the scroll only stops it, and the element isn't pressed although `tap` succeeds. Keep swipe start points away from the navigation bar and the home indicator (the top and bottom edges of the screen).
