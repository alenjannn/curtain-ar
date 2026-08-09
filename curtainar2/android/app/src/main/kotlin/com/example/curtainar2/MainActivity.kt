package com.example.curtainar2

import com.xraph.plugin.flutter_unity_widget.FlutterUnityActivity

// Unity 6's embedded player (and AR Foundation) looks for an mUnityPlayer
// field on the host activity. FlutterUnityActivity provides that field while
// retaining FlutterActivity behaviour. Using plain FlutterActivity lets the
// platform view be created but prevents Unity from starting its scene.
class MainActivity : FlutterUnityActivity()
