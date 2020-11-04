part of "main.dart";

/*
*******************************************
***************** Events ******************
*******************************************

FILTER PANEL:
- Author/title filter changed => FILTER
- Places filter changed => FILTER (permission for Address Book if My Places)
- Language filter changed => FILTER
- Genre filter changed => FILTER
- Filter panel opened => FILTER
- Filter panel minimized => FILTER
- Filter panel closed => FILTER

TRIPLE BUTTON
- Map button pressed => FILTER
- List button pressed => FILTER
- Set view => FILTER

MAP VIEW
- Map move => FILTER
- Tap on Marker => FILTER

DETAILS
- Search button pressed => FILTER

*******************************************
***************** States ******************
*******************************************

FILTER => Map scale and position
FILTER => Book filter changed

*/

enum FilterType { author, title, genre, language, place, wish, contacts }

class Filter extends Equatable {
  final FilterType type;
  final String value;
  final bool selected;

  @override
  List<Object> get props => [type, value, selected];

  const Filter({@required this.type, this.value, this.selected});

  Filter copyWith({
    FilterType type,
    String value,
    bool selected,
  }) {
    return Filter(
      type: type ?? this.type,
      value: value ?? this.value,
      selected: selected ?? this.selected,
    );
  }
}

String up(String geohash) {
  int len = geohash.length;

  if (len >= 1) {
    int lastChar = geohash.codeUnitAt(len - 1);
    return geohash.substring(0, len - 1) + String.fromCharCode(lastChar + 1);
  } else {
    return geohash;
  }
}

enum PanelPosition { hiden, minimized, open }

enum ViewType { map, list, details, camera }

class FilterState extends Equatable {
  final Map<FilterType, List<Filter>> filters;
  final PanelPosition position;
  final LatLng center;
  final double zoom;
  final Set<String> geohashes;
  final ViewType view;
  final List<Book> books;
  final Map<String, Set<Marker>> markers;

  @override
  List<Object> get props =>
      [filters, position, center, zoom, geohashes, view, books, markers];

  const FilterState(
      {this.filters = const {
        FilterType.title: [Filter(type: FilterType.wish, selected: false)],
        FilterType.genre: [],
        FilterType.place: [Filter(type: FilterType.contacts, selected: false)],
        FilterType.language: [],
      },
      this.position = PanelPosition.minimized,
      this.center = const LatLng(37.42796133580664, -122.085749655962),
      this.zoom = 5.0,
      this.geohashes = const {'9q9hv'},
      this.view,
      this.books,
      this.markers});

  FilterState copyWith(
      {Map<FilterType, List<Filter>> filters,
      PanelPosition position,
      LatLng center,
      double zoom,
      ViewType view,
      Set<String> geohashes,
      List<Book> books,
      Map<String, Set<Marker>> markers}) {
    return FilterState(
      filters: filters ?? this.filters,
      position: position ?? this.position,
      center: center ?? this.center,
      zoom: zoom ?? this.zoom,
      view: view ?? this.view,
      geohashes: geohashes ?? this.geohashes,
      books: books ?? this.books,
      markers: markers ?? this.markers,
    );
  }

  List<Filter> getSelected() {
    return [
      ...filters[FilterType.title]
          .where((f) =>
              (f.type == FilterType.author || f.type == FilterType.title) &&
              f.selected)
          .toList(),
      ...filters[FilterType.genre].where((f) => f.selected).toList(),
      ...filters[FilterType.place]
          .where((f) => (f.type == FilterType.place) && f.selected)
          .toList(),
      ...filters[FilterType.language].where((f) => f.selected).toList(),
    ];
  }

  Future<List<Book>> booksFor(String geohash) async {
    String low = (geohash + '000000000').substring(0, 9);
    String high = (geohash + 'zzzzzzzzz').substring(0, 9);

    QuerySnapshot bookSnap = await FirebaseFirestore.instance
        .collection('books')
        .where('location.geohash', isGreaterThanOrEqualTo: low)
        .where('location.geohash', isLessThan: high)
        .limit(2000)
        .get();

    // Group all books for geohash areas one level down
    List<Book> books =
        bookSnap.docs.map((doc) => Book.fromJson(doc.id, doc.data())).toList();

    print('!!!DEBUG: booksFor reads ${books.length} books');

    return books;
  }

  Future<Set<Marker>> markersFor(
      String geohash, List<Book> books, devicePixelRatio) async {
    int level = min(geohash.length + 2, 9);

    Set<Marker> markers = Set();

    if (books != null && books.length > 0) {
      // Group all books for geohash areas one level down
      Map<String, List<Book>> booktree =
          groupBy(books, (book) => book.geohash.substring(0, level));

      List<int> sizes = booktree.values.map((value) => value.length).toList();
      int maxGroup = sizes.reduce(max);
      int minGroup = sizes.reduce(min);
      double minR = 30.0, maxR = 45.0;

      await Future.forEach(booktree.keys, (key) async {
        List<Book> value = booktree[key];
        if (value.length > 1) {
          // Calculate position for the marker via average geo-hash code
          double lat = 0.0, lng = 0.0;
          value.forEach((b) {
            lat += b.location.latitude;
            lng += b.location.longitude;
          });

          lat /= value.length;
          lng /= value.length;

          double radius = ((value.length - minGroup) *
                      (maxR - minR) /
                      (maxGroup - minGroup) +
                  minR) *
              devicePixelRatio;

          markers.add(GroupMarker(
              markerId: MarkerId(key),
              geohash: key,
              position: LatLng(lat, lng),
              icon: await getClusterMarker(
                value.length,
                radius,
              ),
              books: value));
        } else {
          Book book = value[0];
          markers.add(BookMarker(markerId: MarkerId(book.id), book: book));
        }
      });
    }

    print('!!!DEBUG markersFor: ${markers.length}');

    return markers;
  }
}

// Return length of longest common prefix
int lcp(String s1, String s2) {
  for (int i = 0; i <= min(s1.length, s2.length); i++)
    if (s1.codeUnitAt(i) != s2.codeUnitAt(i)) return i;
  return min(s1.length, s2.length);
}

class FilterCubit extends Cubit<FilterState> {
  FilterCubit(double devicePixelRatio) : super(FilterState()) {
    List<Book> books;
    Map<String, Set<Marker>> markers = {};
    Future.forEach(state.geohashes, (hash) async {
      books = await state.booksFor(hash);
      markers[hash] = await state.markersFor(hash, books, devicePixelRatio);
    }).then((value) {
      emit(state.copyWith(
        books: books,
        markers: markers,
        view: ViewType.map,
      ));
    });
  }

  double screenInKm() {
    return 156543.03392 *
        cos(state.center.latitude * pi / 180) /
        pow(2, state.zoom) *
        600.0 /
        1000;
  }

  double distanceBetween(LatLng p1, LatLng p2) {
    double lat1 = p1.latitude;
    double lon1 = p1.longitude;
    double lat2 = p2.latitude;
    double lon2 = p2.longitude;

    double R = 6378.137; // Radius of earth in KM
    double dLat = lat2 * pi / 180 - lat1 * pi / 180;
    double dLon = lon2 * pi / 180 - lon1 * pi / 180;
    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);
    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    double d = R * c;
    return d; // Km
  }

  // FILTER PANEL:
  // - Author/title filter changed => FILTER
  // - Places filter changed => FILTER (permission for Address Book if My Places)
  // - Language filter changed => FILTER
  // - Genre filter changed => FILTER
  void changeFilters(
      FilterType type, List<Filter> filter, double devicePixelRatio) async {
    // TODO: Set filter for given conditions, so only requested books are
    //        displayed. Probably zoom out to contains more copies of this book.

    List<Book> books;
    Map<String, Set<Marker>> markers;
    await Future.forEach(state.geohashes, (hash) async {
      books = await state.booksFor(hash);
      markers[hash] = await state.markersFor(hash, books, devicePixelRatio);
    });

    emit(state.copyWith(
      books: books,
      markers: markers,
      view: ViewType.map,
    ));
  }

  // FILTER PANEL:
  // - Author/title filter changed => FILTER
  // - Places filter changed => FILTER (permission for Address Book if My Places)
  // - Language filter changed => FILTER
  // - Genre filter changed => FILTER
  void toggleFilter(
      FilterType type, Filter filter, double devicePixelRatio) async {
    // TODO: Set filter for given conditions, so only requested books are
    //        displayed. Probably zoom out to contains more copies of this book.

    List<Book> books;
    Map<String, Set<Marker>> markers;
    await Future.forEach(state.geohashes, (hash) async {
      books = await state.booksFor(hash);
      markers[hash] = await state.markersFor(hash, books, devicePixelRatio);
    });

    emit(state.copyWith(
      books: books,
      markers: markers,
      view: ViewType.map,
    ));
  }

  // FILTER PANEL:
  // - Filter panel opened => FILTER
  void panelOpened() {
    emit(state.copyWith(
      position: PanelPosition.open,
    ));
  }

  // FILTER PANEL:
  // - Filter panel minimized => FILTER
  void panelMinimized() {
    emit(state.copyWith(
      position: PanelPosition.minimized,
    ));
  }

  // FILTER PANEL:
  // - Filter panel closed => FILTER
  void panelHiden() {
    emit(state.copyWith(
      position: PanelPosition.hiden,
    ));
  }

  // TRIPLE BUTTON
  // - Map button pressed (selected) => FILTER
  void mapButtonPressed() async {
    Position loc = await Geolocator.getCurrentPosition();

    emit(state.copyWith(
      center: LatLng(loc.latitude, loc.longitude),
      zoom: 14.0,
    ));
    // TODO: Check if zoom reset is a good thing. Do we need to
    //       auto-calculate zoom to always contain some book search results.
  }

  // TRIPLE BUTTON
  // - List button pressed (selected) => FILTER
  void listButtonPressed() {
    // TODO: Which function is appropriate for list view button?
  }

  // TRIPLE BUTTON
  // - Set view => FILTER
  void setView(ViewType view) {
    if (view == ViewType.list) {
      // Sort books based on a distance to the center of the Map screen
      List<Book> books = state.books;

      books.sort((a, b) => (distanceBetween(a.location, state.center) -
              distanceBetween(b.location, state.center))
          .round());

      emit(state.copyWith(
        books: books,
        view: ViewType.list,
      ));
    }

    emit(state.copyWith(
      view: view,
    ));
  }

  // MAP VIEW
  // - Map move => FILTER
  void mapMoved(CameraPosition position, LatLngBounds bounds,
      double devicePixelRatio) async {
    print('!!!DEBUG mapMoved: starting hashes ${state.geohashes.join(',')}');

    // Recalculate geo-hashes from camera position and bounds
    GeoHasher gc = GeoHasher();
    String ne =
        gc.encode(bounds.northeast.longitude, bounds.northeast.latitude);
    String sw =
        gc.encode(bounds.southwest.longitude, bounds.southwest.latitude);
    String nw =
        gc.encode(bounds.southwest.longitude, bounds.northeast.latitude);
    String se =
        gc.encode(bounds.northeast.longitude, bounds.southwest.latitude);
    String center = position != null
        ? gc.encode(position.target.longitude, position.target.latitude)
        : gc.encode(state.center.longitude, state.center.latitude);

    // Find longest common starting substring for center and corners
    int level = max(max(lcp(center, ne), lcp(center, sw)),
        max(lcp(center, nw), lcp(center, se)));

    Set<String> hashes = [
      ne.substring(0, level),
      sw.substring(0, level),
      nw.substring(0, level),
      se.substring(0, level)
    ].toSet();

    print('!!!DEBUG mapMoved: new hashes ${hashes.join(',')}');

    // Old level of geo hashes
    int oldLevel = state.geohashes.first.length;

    // Do nothing if all new geo-hashes already present in the state
    if (oldLevel == level && state.geohashes.containsAll(hashes)) return;

    List<Book> books = state.books;

    // Only list hashes which are of higher level or not included in current
    // set of hashes and not a sub-hashes.
    Set<String> toAddBooks = hashes
        .where((hash) =>
            hash.length < oldLevel ||
            !state.geohashes.contains(hash.substring(0, oldLevel)))
        .toSet();

    // Remove books which are out of the hash areas
    if (books != null) {
      books.removeWhere((b) => !hashes.contains(b.geohash.substring(0, level)));
    } else {
      print('!!!DEBUG books is NULL');
      books = [];
    }

    // Add books only for missing areas
    await Future.forEach(toAddBooks, (hash) async {
      books.addAll(await state.booksFor(hash));
    });

    // Remove duplicates (Duplicates appeared on zoom-out)
    books = books.toSet().toList();

    Map<String, Set<Marker>> markers = state.markers;
    // Remove markers clusters. If same level remove hiden, otherwise all.
    if (level == oldLevel)
      markers.removeWhere((key, value) => !hashes.contains(key));
    else
      markers.clear();

    Set<String> toAddMarkers = hashes.difference(state.geohashes);

    // Add markers for extra geo-hashes
    await Future.forEach(toAddMarkers, (hash) async {
      markers[hash] = await state.markersFor(hash, books, devicePixelRatio);
    });

    // !!!DEBUG
    markers.forEach((key, value) {
      print('!!!DEBUG $key: ${value.length} markers');
    });

    books.sort((a, b) => (distanceBetween(a.location, state.center) -
            distanceBetween(b.location, state.center))
        .round());
    // Emit state with updated markers

    emit(state.copyWith(
        center: position != null ? position.target : state.center,
        zoom: position != null ? position.zoom : state.zoom,
        geohashes: hashes,
        books: books,
        markers: markers));
  }

  // MAP VIEW
  // - Tap on Marker => FILTER
  void markerPressed(Marker marker) {
    if (marker is BookMarker) {
      // Open detailes screen if marker is for one book
      emit(state.copyWith(
        books: [marker.book],
        view: ViewType.details,
      ));
    } else if (marker is GroupMarker) {
      // Zoom in if marker has too many books
      emit(state.copyWith(
        books: marker.books,
        view: ViewType.list,
      ));
    }

    // TODO: If group marker contains too many books zoom-in map
    //       instead of opening list view.
  }

  // DETAILS
  // - Search button pressed => FILTER
  void searchBookPressed(Book book, double devicePixelRatio) async {
    // TODO: Set filter for given book, so only this book is displayed
    //       probably zoom out to contains more copies of this book.

    List<Book> books;
    Map<String, Set<Marker>> markers;
    await Future.forEach(state.geohashes, (hash) async {
      books = await state.booksFor(hash);
      markers[hash] = await state.markersFor(hash, books, devicePixelRatio);
    });

    emit(state.copyWith(
      books: books,
      markers: markers,
      view: ViewType.map,
    ));
  }
}
