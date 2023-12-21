import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_place_picker/google_maps_place_picker.dart';
import 'package:google_maps_place_picker/providers/place_provider.dart';
import 'package:google_maps_place_picker/src/components/animated_pin.dart';
import 'package:google_maps_place_picker/src/components/floating_card.dart';
import 'package:google_maps_place_picker/src/models/map_icon_position.dart';
import 'package:google_maps_place_picker/src/place_picker.dart';
import 'package:google_maps_webservice/geocoding.dart';
import 'package:google_maps_webservice/places.dart';
import 'package:provider/provider.dart';
import 'package:tuple/tuple.dart';

typedef SelectedPlaceWidgetBuilder = Widget Function(
  BuildContext context,
  PickResult? selectedPlace,
  SearchingState state,
  bool isSearchBarFocused,
);

typedef PinBuilder = Widget Function(
  BuildContext context,
  PinState state,
);

class GoogleMapPlacePicker extends StatelessWidget {
  const GoogleMapPlacePicker({
    Key? key,
    required this.initialTarget,
    required this.appBarKey,
    this.selectedPlaceWidgetBuilder,
    this.pinBuilder,
    this.onSearchFailed,
    this.onMoveStart,
    this.onMapCreated,
    this.debounceMilliseconds,
    this.enableMapTypeButton,
    this.enableMyLocationButton,
    this.onToggleMapType,
    this.onMyLocation,
    this.onPlacePicked,
    this.usePinPointingSearch,
    this.usePlaceDetailSearch,
    this.selectInitialPosition,
    this.language,
    this.forceSearchOnZoomChanged,
    this.hidePlaceDetailsWhenDraggingPin,
    this.defaultZoom = 15,
    this.showCurrentLocationIcon = false,
    this.customLocationButton,
  }) : super(key: key);

  final LatLng initialTarget;
  final GlobalKey appBarKey;

  final SelectedPlaceWidgetBuilder? selectedPlaceWidgetBuilder;
  final PinBuilder? pinBuilder;

  final ValueChanged<String>? onSearchFailed;
  final VoidCallback? onMoveStart;
  final MapCreatedCallback? onMapCreated;
  final VoidCallback? onToggleMapType;
  final VoidCallback? onMyLocation;
  final ValueChanged<PickResult>? onPlacePicked;

  final int? debounceMilliseconds;
  final bool? enableMapTypeButton;
  final bool? enableMyLocationButton;

  final bool? usePinPointingSearch;
  final bool? usePlaceDetailSearch;

  final bool? selectInitialPosition;

  final String? language;

  final bool? forceSearchOnZoomChanged;
  final bool? hidePlaceDetailsWhenDraggingPin;
  final double? defaultZoom;
  final bool? showCurrentLocationIcon;
  final Widget? customLocationButton;

  _searchByCameraLocation(PlaceProvider provider) async {
    // We don't want to search location again if camera location is changed by zooming in/out.
    bool hasZoomChanged = provider.cameraPosition != null &&
        provider.prevCameraPosition != null &&
        provider.cameraPosition!.zoom != provider.prevCameraPosition!.zoom;

    if (forceSearchOnZoomChanged == false && hasZoomChanged) {
      provider.placeSearchingState = SearchingState.Idle;
      return;
    }

    provider.placeSearchingState = SearchingState.Searching;

    final GeocodingResponse response = await provider.geocoding.searchByLocation(
      Location(lat: provider.cameraPosition!.target.latitude, lng: provider.cameraPosition!.target.longitude),
      language: language,
    );

    if (response.errorMessage?.isNotEmpty == true || response.status == "REQUEST_DENIED") {
      print("Camera Location Search Error: " + response.errorMessage!);
      if (onSearchFailed != null) {
        onSearchFailed!(response.status);
      }
      provider.placeSearchingState = SearchingState.Idle;
      return;
    }

    if (usePlaceDetailSearch!) {
      final PlacesDetailsResponse detailResponse = await provider.places.getDetailsByPlaceId(
        response.results[0].placeId,
        language: language,
      );

      if (detailResponse.errorMessage?.isNotEmpty == true || detailResponse.status == "REQUEST_DENIED") {
        print("Fetching details by placeId Error: " + detailResponse.errorMessage!);
        if (onSearchFailed != null) {
          onSearchFailed!(detailResponse.status);
        }
        provider.placeSearchingState = SearchingState.Idle;
        return;
      }

      provider.selectedPlace = PickResult.fromPlaceDetailResult(detailResponse.result);
    } else {
      provider.selectedPlace = PickResult.fromGeocodingResult(response.results[0]);
    }

    provider.placeSearchingState = SearchingState.Idle;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        _buildGoogleMap(context),
        _buildPin(),
        _buildFloatingCard(context),
      ],
    );
  }

  Widget _buildGoogleMap(BuildContext context) {
    return Selector<PlaceProvider, MapType>(
        selector: (_, provider) => provider.mapType,
        builder: (_, data, __) {
          PlaceProvider provider = PlaceProvider.of(context, listen: false);
          CameraPosition initialCameraPosition = CameraPosition(target: initialTarget, zoom: defaultZoom!);

          return GoogleMap(
            myLocationButtonEnabled: false,
            compassEnabled: false,
            mapToolbarEnabled: false,
            initialCameraPosition: initialCameraPosition,
            mapType: data,
            myLocationEnabled: showCurrentLocationIcon!,
            onMapCreated: (GoogleMapController controller) {
              provider.mapController = controller;
              provider.setCameraPosition(null);
              provider.pinState = PinState.Idle;

              // When select initialPosition set to true.
              if (selectInitialPosition!) {
                provider.setCameraPosition(initialCameraPosition);
                _searchByCameraLocation(provider);
              }
            },
            onCameraIdle: () {
              if (provider.isAutoCompleteSearching) {
                provider.isAutoCompleteSearching = false;
                provider.pinState = PinState.Idle;
                return;
              }

              // Perform search only if the setting is to true.
              if (usePinPointingSearch!) {
                // Search current camera location only if camera has moved (dragged) before.
                if (provider.pinState == PinState.Dragging) {
                  // Cancel previous timer.
                  if (provider.debounceTimer?.isActive ?? false) {
                    provider.debounceTimer!.cancel();
                  }
                  provider.debounceTimer = Timer(Duration(milliseconds: debounceMilliseconds!), () {
                    _searchByCameraLocation(provider);
                  });
                }
              }

              provider.pinState = PinState.Idle;
            },
            onCameraMoveStarted: () {
              provider.setPrevCameraPosition(provider.cameraPosition);

              // Cancel any other timer.
              provider.debounceTimer?.cancel();

              // Update state, dismiss keyboard and clear text.
              provider.pinState = PinState.Dragging;

              // Begins the search state if the hide details is enabled
              if (this.hidePlaceDetailsWhenDraggingPin!) {
                provider.placeSearchingState = SearchingState.Searching;
              }

              onMoveStart!();
            },
            onCameraMove: (CameraPosition position) {
              provider.setCameraPosition(position);
            },
            // gestureRecognizers make it possible to navigate the map when it's a
            // child in a scroll view e.g ListView, SingleChildScrollView...
            gestureRecognizers: Set()..add(Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer())),
          );
        });
  }

  Widget _buildPin() {
    return Center(
      child: Selector<PlaceProvider, PinState>(
        selector: (_, provider) => provider.pinState,
        builder: (context, state, __) {
          if (pinBuilder == null) {
            return _defaultPinBuilder(context, state);
          } else {
            return Builder(builder: (builderContext) => pinBuilder!(builderContext, state));
          }
        },
      ),
    );
  }

  Widget _defaultPinBuilder(BuildContext context, PinState state) {
    if (state == PinState.Preparing) {
      return Container();
    } else if (state == PinState.Idle) {
      return Stack(
        children: <Widget>[
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.place, size: 36, color: Colors.red),
                SizedBox(height: 42),
              ],
            ),
          ),
          Center(
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      );
    } else {
      return Stack(
        children: <Widget>[
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                AnimatedPin(child: Icon(Icons.place, size: 36, color: Colors.red)),
                SizedBox(height: 42),
              ],
            ),
          ),
          Center(
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      );
    }
  }

  Widget _buildFloatingCard(BuildContext context) {
    return Container(
      child: Selector<PlaceProvider, Tuple4<PickResult?, SearchingState, bool, PinState>>(
        selector: (_, provider) => Tuple4(
            provider.selectedPlace, provider.placeSearchingState, provider.isSearchBarFocused, provider.pinState),
        builder: (context, data, __) {
          if ((data.item1 == null && data.item2 == SearchingState.Idle) ||
              data.item3 == true ||
              data.item4 == PinState.Dragging && this.hidePlaceDetailsWhenDraggingPin!) {
            return Container();
          } else {
            if (selectedPlaceWidgetBuilder == null) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _buildMapIcons(context),
                  _defaultPlaceWidgetBuilder(context, data.item1, data.item2),
                ],
              );
            } else {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _buildMapIcons(context),
                  Builder(
                    builder: (builderContext) => selectedPlaceWidgetBuilder!(
                      builderContext,
                      data.item1,
                      data.item2,
                      data.item3,
                    ),
                  ),
                ],
              );
            }
          }
        },
      ),
    );
  }

  Widget _defaultPlaceWidgetBuilder(BuildContext context, PickResult? data, SearchingState state) {
    return Center(
      child: RoundedFrame(
        width: MediaQuery.of(context).size.width * 0.9,
        borderRadius: BorderRadius.circular(12.0),
        elevation: 4.0,
        color: Theme.of(context).cardColor,
        child: state == SearchingState.Searching ? _buildLoadingIndicator() : _buildSelectionDetails(context, data!),
      ),
    );
    // return FloatingCard(
    //   bottomPosition: MediaQuery.of(context).size.height * 0.05,
    //   leftPosition: MediaQuery.of(context).size.width * 0.025,
    //   rightPosition: MediaQuery.of(context).size.width * 0.025,
    //   width: MediaQuery.of(context).size.width * 0.9,
    //   borderRadius: BorderRadius.circular(12.0),
    //   elevation: 4.0,
    //   color: Theme.of(context).cardColor,
    //   child: state == SearchingState.Searching ? _buildLoadingIndicator() : _buildSelectionDetails(context, data!),
    // );
  }

  Widget _buildLoadingIndicator() {
    return Container(
      height: 48,
      child: const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }

  Widget _buildSelectionDetails(BuildContext context, PickResult result) {
    return Container(
      margin: EdgeInsets.all(10),
      child: Column(
        children: <Widget>[
          Text(
            result.formattedAddress!,
            style: TextStyle(fontSize: 18),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 10),
          TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4.0),
              ),
            ),
            child: Text(
              "Select here",
              style: TextStyle(fontSize: 16),
            ),
            onPressed: () {
              onPlacePicked!(result);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMapIcons(BuildContext context) {
    final RenderBox appBarRenderBox = appBarKey.currentContext!.findRenderObject() as RenderBox;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        enableMapTypeButton!
            ? GestureDetector(
                onTap: onToggleMapType,
                child: Container(
                  margin: EdgeInsets.only(right: 16, bottom: 10),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(Icons.layers),
                ),
              )
            : Container(),
        enableMyLocationButton! ? _myLocationButton() : Container(),
      ],
    );
  }

  _myLocationButton() {
    if (customLocationButton != null) {
      return GestureDetector(
        onTap: onMyLocation,
        child: customLocationButton,
      );
    }
    return GestureDetector(
      onTap: onMyLocation,
      child: Container(
        padding: EdgeInsets.all(8),
        margin: EdgeInsets.only(right: 16, bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(Icons.my_location),
      ),
    );
  }
}
