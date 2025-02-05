import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

void main() {
  runApp(
    const MaterialApp(
      home: UnityDemoScreen(),
    ),
  );
}

class UnityDemoScreen extends StatefulWidget {
  const UnityDemoScreen({Key? key}) : super(key: key);

  @override
  State<UnityDemoScreen> createState() => _UnityDemoScreenState();
}

class _UnityDemoScreenState extends State<UnityDemoScreen> {

  UnityWidgetController? _unityWidgetController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            UnityWidget(
              onUnityCreated: onUnityCreated,
              onUnitySceneLoaded: onUnitySceneLoaded,
              onUnityMessage: onUnityMessage,
            ),
Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    MaterialButton(onPressed: (){
      Map<String, dynamic> playerData = {
        "speed": 3,
        "name": "player",
        "health": 100,
        "position": {"x": 10, "y": 5, "z": 0},
        "abilities": ["jump", "run", "dash"],
        "isActive": true,
      };
final encodedString = jsonEncode(playerData);
      setMoveSpeed(encodedString);
    }, child: const Text("Set Speed At 1")),
    const SizedBox(height: 30),
  ],
),
          ],
        ),
      ),
    );
  }

  void setMoveSpeed(String playerData) {
    _unityWidgetController?.postMessage(
      'Cube',
      'SetMoveSpeed',
      playerData,
    );
  }

  void onUnityMessage(message) {
    print('Received message from unity: ${message.toString()}');
  }

  void onUnitySceneLoaded(SceneLoaded? scene) {
    if (scene != null) {
      print('Received scene loaded from unity: ${scene.name}');
      print('Received scene loaded from unity buildIndex: ${scene.buildIndex}');
    } else {
      print('Received scene loaded from unity: null');
    }
  }

  void onUnityCreated(controller) {
    controller.resume();
    _unityWidgetController = controller;
  }

}