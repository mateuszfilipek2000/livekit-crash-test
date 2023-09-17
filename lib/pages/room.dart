import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../exts.dart';
import '../widgets/controls.dart';
import '../widgets/participant.dart';
import '../widgets/participant_info.dart';

class RoomPage extends StatefulWidget {
  //
  final Room room;
  final EventsListener<RoomEvent> listener;

  const RoomPage(
    this.room,
    this.listener, {
    Key? key,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  //
  List<ParticipantTrack> participantTracks = [];
  EventsListener<RoomEvent> get _listener => widget.listener;
  bool get fastConnection => widget.room.engine.fastConnectOptions != null;
  bool blockAutoUpdate = false;
  @override
  void initState() {
    super.initState();
    // add callback for a `RoomEvent` as opposed to a `ParticipantEvent`
    widget.room.addListener(_onRoomDidUpdate);
    // add callbacks for finer grained events
    _setUpListeners();
    _sortParticipants();
    WidgetsBindingCompatible.instance?.addPostFrameCallback((_) {
      if (!fastConnection) {
        _askPublish();
      }
    });

    if (lkPlatformIsMobile()) {
      Hardware.instance.setSpeakerphoneOn(true);
    }
  }

  @override
  void dispose() {
    // always dispose listener
    (() async {
      widget.room.removeListener(_onRoomDidUpdate);
      await _listener.dispose();
      await widget.room.dispose();
    })();
    super.dispose();
  }

  /// for more information, see [event types](https://docs.livekit.io/client/events/#events)
  void _setUpListeners() => _listener
    ..on<RoomDisconnectedEvent>((event) async {
      if (event.reason != null) {
        print('Room disconnected: reason => ${event.reason}');
      }
      WidgetsBindingCompatible.instance
          ?.addPostFrameCallback((timeStamp) => Navigator.pop(context));
    })
    ..on<ParticipantEvent>((event) {
      print('Participant event');
      // sort participants on many track events as noted in documentation linked above
      _sortParticipants();
    })
    ..on<RoomRecordingStatusChanged>((event) {
      context.showRecordingStatusChangedDialog(event.activeRecording);
    })
    ..on<LocalTrackPublishedEvent>((_) => _sortParticipants())
    ..on<LocalTrackUnpublishedEvent>((_) => _sortParticipants())
    ..on<TrackE2EEStateEvent>(_onE2EEStateEvent)
    ..on<ParticipantNameUpdatedEvent>((event) {
      print(
          'Participant name updated: ${event.participant.identity}, name => ${event.name}');
    })
    ..on<DataReceivedEvent>((event) {
      String decoded = 'Failed to decode';
      try {
        decoded = utf8.decode(event.data);
      } catch (_) {
        print('Failed to decode: $_');
      }
      context.showDataReceivedDialog(decoded);
    })
    ..on<AudioPlaybackStatusChanged>((event) async {
      if (!widget.room.canPlaybackAudio) {
        print('Audio playback failed for iOS Safari ..........');
        bool? yesno = await context.showPlayAudioManuallyDialog();
        if (yesno == true) {
          await widget.room.startAudio();
        }
      }
    });

  void _askPublish() async {
    final result = await context.showPublishDialog();
    if (result != true) return;
    // video will fail when running in ios simulator
    try {
      await widget.room.localParticipant?.setCameraEnabled(true);
    } catch (error) {
      print('could not publish video: $error');
      await context.showErrorDialog(error);
    }
    try {
      await widget.room.localParticipant?.setMicrophoneEnabled(true);
    } catch (error) {
      print('could not publish audio: $error');
      await context.showErrorDialog(error);
    }
  }

  void _onRoomDidUpdate() {
    if (blockAutoUpdate) return;
    _sortParticipants();
  }

  void _onE2EEStateEvent(TrackE2EEStateEvent e2eeState) {
    print('e2ee state: $e2eeState');
  }

  void _trigerFocus(ParticipantTrack track) {
    // if there are multiple tracks, focus on the one that was tapped
    setState(() {
      if (participantTracks.length == 1) {
        blockAutoUpdate = false;
        _onRoomDidUpdate();
        return;
      }

      blockAutoUpdate = true;
      participantTracks = [track];
    });
  }

  void _sortParticipants() {
    List<ParticipantTrack> userMediaTracks = [];
    List<ParticipantTrack> screenTracks = [];
    for (var participant in widget.room.participants.values) {
      for (var t in participant.videoTracks) {
        if (t.isScreenShare) {
          screenTracks.add(ParticipantTrack(
            participant: participant,
            videoTrack: t.track,
            isScreenShare: true,
          ));
        } else {
          userMediaTracks.add(ParticipantTrack(
            participant: participant,
            videoTrack: t.track,
            isScreenShare: false,
          ));
        }
      }
    }

    final participantTracksWithoutVideoTracks = widget.room.participants.values
        .where((p) => p.videoTracks.isEmpty)
        .map((p) => ParticipantTrack(
              participant: p,
              videoTrack: null,
              isScreenShare: false,
            ));

    userMediaTracks.addAll(participantTracksWithoutVideoTracks);

    // sort speakers for the grid
    userMediaTracks.sort((a, b) {
      // loudest speaker first
      if (a.participant.isSpeaking && b.participant.isSpeaking) {
        if (a.participant.audioLevel > b.participant.audioLevel) {
          return -1;
        } else {
          return 1;
        }
      }

      // last spoken at
      final aSpokeAt = a.participant.lastSpokeAt?.millisecondsSinceEpoch ?? 0;
      final bSpokeAt = b.participant.lastSpokeAt?.millisecondsSinceEpoch ?? 0;

      if (aSpokeAt != bSpokeAt) {
        return aSpokeAt > bSpokeAt ? -1 : 1;
      }

      // video on
      if (a.participant.hasVideo != b.participant.hasVideo) {
        return a.participant.hasVideo ? -1 : 1;
      }

      // joinedAt
      return a.participant.joinedAt.millisecondsSinceEpoch -
          b.participant.joinedAt.millisecondsSinceEpoch;
    });

    final localParticipantTracks = widget.room.localParticipant?.videoTracks;
    if (localParticipantTracks != null) {
      for (var t in localParticipantTracks) {
        if (t.isScreenShare) {
          screenTracks.add(ParticipantTrack(
            participant: widget.room.localParticipant!,
            videoTrack: t.track,
            isScreenShare: true,
          ));
        } else {
          userMediaTracks.add(ParticipantTrack(
            participant: widget.room.localParticipant!,
            videoTrack: t.track,
            isScreenShare: false,
          ));
        }
      }
    }
    setState(() {
      participantTracks = [...screenTracks, ...userMediaTracks];
    });
  }

  @override
  Widget build(BuildContext context) {
    final (columns, rows) = _getGridDimens(participantTracks.length);

    return Scaffold(
      body: _StaticGrid(
        itemCount: participantTracks.length,
        columns: columns,
        rows: rows,
        verticalSpacing: 8,
        horizontalSpacing: 8,
        itemBuilder: (index) {
          final track = participantTracks[index];

          return GestureDetector(
            onTap: () => _trigerFocus(track),
            behavior: HitTestBehavior.opaque,
            child: ParticipantWidget.widgetFor(track),
          );
        },
        emptyBuilder: () {
          return DecoratedBox(
            decoration: ShapeDecoration(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              color: Colors.grey,
            ),
          );
        },
      ),
    );
  }
}

class _StaticGrid extends StatelessWidget {
  const _StaticGrid({
    required this.itemCount,
    required this.columns,
    required this.rows,
    required this.verticalSpacing,
    required this.horizontalSpacing,
    required this.itemBuilder,
    required this.emptyBuilder,
  });

  final int itemCount;
  final int columns;
  final int rows;
  final double verticalSpacing;
  final double horizontalSpacing;
  final Widget Function(int index) itemBuilder;
  final Widget Function() emptyBuilder;

  @override
  Widget build(BuildContext context) {
    final grid = <Widget>[];

    if (itemCount == 1) {
      // return single element taking all available space
      return itemBuilder(0);
    }

    if (itemCount == 2) {
      for (var i = 0; i < rows; i++) {
        grid.add(
          Expanded(
            child: AspectRatio(
              aspectRatio: 1.6,
              child: itemBuilder(i),
            ),
          ),
        );
      }

      return Row(
        children: grid
            .intersperse(
              SizedBox(
                width: horizontalSpacing,
              ),
            )
            .toList(),
      );
    }

    var currentIndex = 0;

    for (var i = 0; i < columns; i++) {
      final row = <Widget>[];

      for (var j = 0; j < rows; j++) {
        final index = currentIndex++;
        row.add(
          Expanded(
            child: index < itemCount ? itemBuilder(index) : emptyBuilder(),
          ),
        );
      }

      grid.add(
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: row
                .intersperse(
                  SizedBox(
                    width: horizontalSpacing,
                  ),
                )
                .toList(),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: grid
          .intersperse(
            SizedBox(
              height: verticalSpacing,
            ),
          )
          .toList(),
    );
  }
}

extension on List<Widget> {
  Iterable<Widget> intersperse(Widget element) sync* {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      yield iterator.current;
      while (iterator.moveNext()) {
        yield element;
        yield iterator.current;
      }
    }
  }
}

(int, int) _getGridDimens(int participantsCount) {
  final columns = math.sqrt(participantsCount).ceil();
  final rows =
      columns * (columns - 1) >= participantsCount ? columns - 1 : columns;

  return (columns, rows);
}
