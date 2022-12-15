/*
Copyright 2022.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package classification_test

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/klog/v2/klogr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/projectsveltos/classifier-agent/pkg/classification"
	libsveltosv1alpha1 "github.com/projectsveltos/libsveltos/api/v1alpha1"
)

var (
	pods = libsveltosv1alpha1.DeployedResourceConstraint{
		Group:   "",
		Version: "v1",
		Kind:    "Pod",
	}

	kubeadmconfigs = libsveltosv1alpha1.DeployedResourceConstraint{
		Group:   "bootstrap.cluster.x-k8s.io",
		Version: "v1beta1",
		Kind:    "Kubeadmconfig",
	}

	classifiers = libsveltosv1alpha1.DeployedResourceConstraint{
		Group:   "lib.projectsveltos.io",
		Version: "v1alpha1",
		Kind:    "Classifier",
	}

	debuggingConfigurations = libsveltosv1alpha1.DeployedResourceConstraint{
		Group:   "lib.projectsveltos.io",
		Version: "v1alpha1",
		Kind:    "DebuggingConfiguration",
	}
)

var _ = Describe("Manager: watchers", func() {
	var watcherCtx context.Context
	var cancel context.CancelFunc

	BeforeEach(func() {
		classification.Reset()
		watcherCtx, cancel = context.WithCancel(context.Background())
	})

	AfterEach(func() {
		classifiers := &libsveltosv1alpha1.ClassifierList{}
		Expect(testEnv.List(context.TODO(), classifiers)).To(Succeed())

		for i := range classifiers.Items {
			Expect(testEnv.Delete(context.TODO(), &classifiers.Items[i]))
		}

		cancel()
	})

	It("buildList: builds list of resources to watch", func() {
		classifier := getClassifierWithKubernetesConstraints(version25, libsveltosv1alpha1.ComparisonEqual)
		classifier.Spec.DeployedResourceConstraints = []libsveltosv1alpha1.DeployedResourceConstraint{
			pods,
			kubeadmconfigs,
		}
		classifier.Spec.ClassifierLabels = []libsveltosv1alpha1.ClassifierLabel{
			{Key: randomString(), Value: randomString()},
		}

		// Use Eventually so cache is in sync
		Eventually(func() bool {
			err := testEnv.Create(watcherCtx, classifier)
			if err != nil {
				Expect(meta.IsNoMatchError(err)).To(BeTrue())
				return false
			}
			return true
		}, timeout, pollingInterval).Should(BeTrue())

		Eventually(func() error {
			currentClassifier := &libsveltosv1alpha1.Classifier{}
			return testEnv.Get(context.TODO(),
				client.ObjectKey{Name: classifier.Name}, currentClassifier)
		}, timeout, pollingInterval).Should(BeNil())

		classification.InitializeManager(watcherCtx, klogr.New(), testEnv.Config, testEnv.Client,
			randomString(), randomString(), libsveltosv1alpha1.ClusterTypeCapi, nil, 10, false)
		manager := classification.GetManager()
		gvks, err := classification.BuildList(manager, context.TODO())
		Expect(err).To(BeNil())
		Expect(len(gvks)).To(Equal(2))
		for i := range classifier.Spec.DeployedResourceConstraints {
			r := classifier.Spec.DeployedResourceConstraints[i]
			gvk := schema.GroupVersionKind{
				Group:   r.Group,
				Version: r.Version,
				Kind:    r.Kind,
			}
			Expect(gvks[gvk]).To(BeTrue())
		}
	})

	It("buildSortedList creates a sorted list", func() {
		classification.InitializeManager(watcherCtx, klogr.New(), testEnv.Config, testEnv.Client,
			randomString(), randomString(), libsveltosv1alpha1.ClusterTypeSveltos, nil, 10, false)
		manager := classification.GetManager()

		gvk1 := schema.GroupVersionKind{Group: pods.Group, Version: pods.Version, Kind: pods.Kind}
		gvk2 := schema.GroupVersionKind{Group: kubeadmconfigs.Group, Version: kubeadmconfigs.Version, Kind: kubeadmconfigs.Kind}
		gvksMap := map[schema.GroupVersionKind]bool{
			gvk2: true, gvk1: true,
		}
		sortedList := classification.BuildSortedList(manager, gvksMap)
		Expect(len(sortedList)).To(Equal(2))
		Expect(sortedList[0].Kind).To(Equal(pods.Kind))
		Expect(sortedList[1].Kind).To(Equal(kubeadmconfigs.Kind))
	})

	It("gvkInstalled returns true if resource is installed, false otherwise", func() {
		classification.InitializeManager(watcherCtx, klogr.New(), testEnv.Config, testEnv.Client,
			randomString(), randomString(), libsveltosv1alpha1.ClusterTypeSveltos, nil, 10, false)
		manager := classification.GetManager()

		gvk1 := schema.GroupVersionKind{Group: pods.Group, Version: pods.Version, Kind: pods.Kind}
		gvk2 := schema.GroupVersionKind{Group: kubeadmconfigs.Group, Version: kubeadmconfigs.Version, Kind: kubeadmconfigs.Kind}
		gvksMap := map[schema.GroupVersionKind]bool{
			gvk2: true, gvk1: true,
		}

		Expect(classification.GvkInstalled(manager, &gvk1, gvksMap)).To(BeTrue())
		Expect(classification.GvkInstalled(manager, &gvk2, gvksMap)).To(BeTrue())

		gvk3 := schema.GroupVersionKind{
			Group:   "lib.projectsveltos.io",
			Version: "v1alpha1",
			Kind:    "debuggingconfigurations",
		}
		Expect(classification.GvkInstalled(manager, &gvk3, gvksMap)).To(BeFalse())
	})

	It("getInstalledResources returns list of installed api-resources", func() {
		classification.InitializeManager(watcherCtx, klogr.New(), testEnv.Config, testEnv.Client,
			randomString(), randomString(), libsveltosv1alpha1.ClusterTypeSveltos, nil, 10, false)
		manager := classification.GetManager()

		resources, err := classification.GetInstalledResources(manager)
		Expect(err).To(BeNil())
		Expect(resources).ToNot(BeEmpty())

		gvk := schema.GroupVersionKind{Group: pods.Group, Version: pods.Version, Kind: pods.Kind}
		Expect(resources[gvk]).To(BeTrue())

		gvk = schema.GroupVersionKind{Group: classifiers.Group, Version: classifiers.Version, Kind: classifiers.Kind}
		Expect(resources[gvk]).To(BeTrue())
	})

	It("startWatcher starts a watcher when resource is installed", func() {
		classification.InitializeManager(watcherCtx, klogr.New(), testEnv.Config, testEnv.Client,
			randomString(), randomString(), libsveltosv1alpha1.ClusterTypeSveltos, nil, 10, false)
		manager := classification.GetManager()

		gvk := &schema.GroupVersionKind{Group: classifiers.Group, Version: classifiers.Version, Kind: classifiers.Kind}
		Expect(classification.StartWatcher(manager, gvk, nil)).To(BeNil())

		watchers := classification.GetWatchers()
		Expect(watchers).ToNot(BeNil())
		Expect(len(watchers)).To(Equal(1))
		cancel, ok := watchers[*gvk]
		Expect(ok).To(BeTrue())
		cancel()
	})

	It("updateWatchers starts new watchers", func() {
		classification.InitializeManager(watcherCtx, klogr.New(), testEnv.Config, testEnv.Client,
			randomString(), randomString(), libsveltosv1alpha1.ClusterTypeCapi, nil, 10, false)
		manager := classification.GetManager()

		gvk := schema.GroupVersionKind{Group: pods.Group, Version: pods.Version, Kind: pods.Kind}
		resourceToWatch := []schema.GroupVersionKind{gvk}

		Expect(classification.UpdateWatchers(manager, resourceToWatch)).To(Succeed())
		watchers := classification.GetWatchers()
		Expect(watchers).ToNot(BeNil())
		Expect(len(watchers)).To(Equal(1))
		cancel, ok := watchers[gvk]
		Expect(ok).To(BeTrue())
		cancel()
	})

	It("updateWatchers stores resources to watch which are not installed yet", func() {
		classification.InitializeManager(watcherCtx, klogr.New(), testEnv.Config, testEnv.Client,
			randomString(), randomString(), libsveltosv1alpha1.ClusterTypeCapi, nil, 10, false)
		manager := classification.GetManager()

		gvk1 := schema.GroupVersionKind{Group: pods.Group, Version: pods.Version, Kind: pods.Kind}
		gvk2 := schema.GroupVersionKind{Group: debuggingConfigurations.Group,
			Version: debuggingConfigurations.Version, Kind: debuggingConfigurations.Kind}
		resourceToWatch := []schema.GroupVersionKind{gvk1, gvk2}

		Expect(classification.UpdateWatchers(manager, resourceToWatch)).To(Succeed())
		watchers := classification.GetWatchers()
		Expect(watchers).ToNot(BeNil())
		Expect(len(watchers)).To(Equal(1))
		cancel, ok := watchers[gvk1]
		Expect(ok).To(BeTrue())
		cancel()

		unknown := classification.GetUnknownResourcesToWatch()
		Expect(len(unknown)).To(Equal(1))
		Expect(unknown[0].Kind).To(Equal(debuggingConfigurations.Kind))
	})
})
