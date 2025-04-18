/*
 Copyright 2023 Juicedata Inc

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

package dashboard

import (
	"sort"
	"testing"
	"time"

	storagev1 "k8s.io/api/storage/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/juicedata/juicefs-csi-driver/pkg/config"
)

func TestReverse(t *testing.T) {
	time1 := time.Date(2023, 2, 1, 0, 0, 0, 0, time.UTC)
	time2 := time.Date(2023, 1, 1, 0, 0, 0, 0, time.UTC)
	time3 := time.Date(2023, 1, 2, 0, 0, 0, 0, time.UTC)
	data := ListSCResult{
		Total: 3,
		SCs: []*storagev1.StorageClass{
			{ObjectMeta: metav1.ObjectMeta{Name: "test1", CreationTimestamp: metav1.Time{Time: time1}}},
			{ObjectMeta: metav1.ObjectMeta{Name: "test2", CreationTimestamp: metav1.Time{Time: time2}}},
			{ObjectMeta: metav1.ObjectMeta{Name: "test3", CreationTimestamp: metav1.Time{Time: time3}}},
		},
	}
	t.Run("test for reserve", func(t *testing.T) {
		sort.Sort(Reverse(data))
		if data.SCs[0].CreationTimestamp.Before(&data.SCs[1].CreationTimestamp) {
			t.Errorf("sort error")
		}
		if data.SCs[1].CreationTimestamp.Before(&data.SCs[2].CreationTimestamp) {
			t.Errorf("sort error")
		}
	})
}

func TestIsPVCSelectorEmpty(t *testing.T) {
	type args struct {
		selector *config.PVCSelector
	}
	tests := []struct {
		name string
		args args
		want bool
	}{
		{
			name: "",
			args: args{
				selector: &config.PVCSelector{},
			},
			want: true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsPVCSelectorEmpty(tt.args.selector); got != tt.want {
				t.Errorf("IsPVCSelectorEmpty() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestStripDir(t *testing.T) {
	type args struct {
		dir string
	}
	tests := []struct {
		name string
		args args
		want string
	}{
		{
			name: "test1",
			args: args{
				dir: "a\\b",
			},
			want: "a-b",
		},
		{
			name: "test2",
			args: args{
				dir: "a/b",
			},
			want: "a-b",
		},
		{
			name: "test3",
			args: args{
				dir: "a..b",
			},
			want: "a-b",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := StripDir(tt.args.dir); got != tt.want {
				t.Errorf("StripDir() = %v, want %v", got, tt.want)
			}
		})
	}
}
